#!/usr/bin/env perl

use strict;
use warnings;
use 5.014;
use utf8;

use DateTime;
use MediaWiki::API;
use Mojolicious::Lite;

our $VERSION = '0.01';

my $mw = MediaWiki::API->new(
	{
		api_url  => "$ENV{WIKI_URL}/api.php",
		on_error => \&on_error
	}
);
my $mw_error;

sub on_error {
	$mw_error
	  = 'Error code: '
	  . $mw->{error}->{code} . "\n"
	  . $mw->{error}->{stacktrace} . "\n";
	exit 1;
}

sub mw_edit {
	my ( $page, $content ) = @_;

	$mw_error = undef;

	my $timestamp = $mw->get_page( { title => $page } )->{timestamp};
	$mw->edit(
		{
			action        => 'edit',
			title         => $page,
			basetimestamp => $timestamp,
			text          => $content,
			bot           => 1,
		}
	) or $mw_error = $mw->{error}->{code} . ': ' . $mw->{error}->{details};
	return;
}

sub mw_get {
	my ($page) = @_;
	$mw_error = undef;
	return $mw->get_page( { title => $page } )->{'*'};
}

sub trim {
	my ($str) = @_;
	$str =~ s{ ^ \s+ }{}ox;
	$str =~ s{ \s+ $ }{}ox;
	return $str;
}

sub is_float {
	my ($float) = @_;
	return ( $float =~ m{ ^ \d+ (?: [.] \d\d )? $ }x );
}

sub preview {
	my ($self) = @_;
	my $action = $self->param('action') // 'none';
	my $site = $self->param('site');

	my $re_flag = qr{
		! (?<name> \S+ ) (?: \s* [*] \s* (?<value> \d+ [,.] \d+ ) )? }ox;
	my $re_shipping = qr{
		Versand(kosten)? \s* : \s* (?<shipping> \d+ [,.] \d+) }iox;
	my $re_orderline = qr{
		^\| (?<part> [^|]+ ) \|\| (?<desc> [^|]+ ) \|\|
		(?<price> [^|]+ ) \|\| (?<amount> [^|]+ ) \|\|
		(?<sum> [^|]+ ) \|\| (?<nick> [^|]+ ) $ }ox;

	my $content = mw_get("$ENV{WIKI_PREFIX}/$site");
	my @errors;
	my %orders;
	my %flag;
	my $shipping     = 0;
	my $total        = 0;
	my $ymd          = DateTime->now( time_zone => 'Europe/Berlin' )->ymd;
	my $hms          = DateTime->now( time_zone => 'Europe/Berlin' )->hms;
	my $nochangeline = '<!-- automatic changes prohibited -->';
	my $finalized    = 0;
	my $csv          = q{};

	if ( not $content ) {
		$self->render(
			'error',
			error   => "invalid site: $site",
			version => $VERSION
		);
		return;
	}

	for my $line ( split( /\n/, $content ) ) {
		if ($line =~ $re_flag ) {
			my $flagname = lc($+{name});
			my $value = $+{value} || 1;
			$value   =~ tr{,}{.};
			$flag{$flagname} = $value;
		}
		if ( $line =~ $re_shipping ) {
			$shipping = $+{shipping};
			$shipping =~ tr{,}{.};
		}
		elsif ( $line =~ $re_orderline ) {
			my ( $part, $desc, $price, $amount, $sum, $nick )
			  = map { trim($_) } @+{qw{part desc price amount sum nick}};
			$price =~ tr{,}{.};
			$sum   =~ tr{,}{.};

			if ( grep { !is_float($_) } ( $price, $amount, $sum ) ) {
				push(
					@errors,
					sprintf(
						'%s (%s): price, amount or sum is not a '
						  . 'number. skipped. (%s)',
						$part, $desc,
						join( ', ',
							map { "\"$_\"" }
							grep { !is_float($_) } ( $price, $amount, $sum ) )
					)
				);
				next;
			}

			my $calcsum = sprintf( '%.2f', $price * $amount );
			if ( $calcsum != $sum ) {
				push(
					@errors,
					sprintf(
						"%s (%s): provided sum is %.2f, but calculated sum "
						  . "is %.2f == %.2f * %.2f. Δ %.2f. "
						  . "Using provided sum for my calculations.\n",
						$part,  $desc,   $sum, $calcsum,
						$price, $amount, $sum - $calcsum
					)
				);
			}
			if ($flag{mwst}) {
				$sum *= $flag{mwst};
			}
			if ($flag{rabatt}) {
				$sum *= $flag{rabatt};
			}

			$orders{$nick} += $sum;
			$total += $sum;

			$csv .= sprintf( "%s;%d\n", $part, $amount );
		}
	}

	if ( $content =~ m{$nochangeline}s ) {
		$finalized = 1;
	}

	$content =~ s{ \n* === \s* Kosten [^=]* === .* $ }{}sx;

	$content .= "\n\n=== Kosten (Stand $ymd $hms) ===\n\n";

	$content .= "<!-- automatically generated -->\n\n";

	if (@errors) {
		$content .= join( "\n", map { "* $_" } @errors );
		$content .= "\n\n";
	}

	if ($flag{mwstversand} and $flag{mwst}) {
		$shipping *= $flag{mwst};
	}

	$content .= sprintf( "Bestellsumme: %.2f + %.2f == %.2f\n",
		$total, $shipping, $total + $shipping );
	$content .= "{| class=\"wikitable\"\n";
	$content .= "! Wer !! Summe !! Versandkostenanteil !! Gesamt !! Bezahlt\n";

	for my $nick ( sort keys %orders ) {
		my $shippingpart = $shipping * $orders{$nick} / $total;
		$content .= sprintf( "|-\n| %20s || %.2f || %.2f || %.2f || \n",
			$nick, $orders{$nick}, $shippingpart,
			$orders{$nick} + $shippingpart );
	}

	$content .= "|}\n <!-- DO NOT EDIT BELOW THIS LINE -->";

	if ( $action ne 'none' and $finalized ) {
		$self->render(
			'error',
			error   => 'order already placed. automatic changes prohibited',
			version => $VERSION
		);
		return;
	}

	if ( $action eq 'csv' ) {
		$self->res->headers->content_disposition(
			'attachment; filename=reichelt.csv;');
		$self->render(
			data   => $csv,
			format => 'csv',
		);
		return;
	}

	if ( $action eq 'finalize' ) {
		$content .= "\n$nochangeline\n";
	}
	if ( $action ~~ [qw[add finalize]] ) {
		mw_edit( "$ENV{WIKI_PREFIX}/$site", $content );
		if ($mw_error) {
			$self->render(
				'error',
				error   => $mw_error,
				version => $VERSION
			);
		}
		else {
			$self->redirect_to(
				"$ENV{WIKI_URL}/$ENV{WIKI_PREFIX}/$site");
		}
		return;
	}

	$self->render(
		'main',
		errors   => \@errors,
		order    => \%orders,
		total    => $total,
		shipping => $shipping,
		site     => $site,
		version  => $VERSION,
	);
	return;
}

sub help {
	my ($self) = @_;

	$self->render(
		'help',
		layout  => 'pod',
		version => $VERSION,
	);
}

$mw->login(
	{
		lgname     => $ENV{WIKI_USER},
		lgpassword => $ENV{WIKI_PASSWORD},
		lgdomain   => 'local',
	}
);

get '/'     => \&preview;
get '/help' => \&help;

app->config(
	hypnotoad => {
		listen   => ['http://*:8098'],
		pid_file => '/tmp/mediawiki-orderhelper.pid',
		workers  => 1,
	},
);
app->defaults( layout => 'default' );

plugin PODRenderer => {
	no_perldoc => 1,
	preprocess => 'ep'
};

app->start;
