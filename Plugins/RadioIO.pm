# $Id: RadioIO.pm,v 1.2 2004/10/06 15:56:01 vidur Exp $

# SlimServer Copyright (c) 2001-2004 Vidur Apparao, Slim Devices Inc.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
package Plugins::RadioIO;

use FileHandle;
use IO::Socket qw(:DEFAULT :crlf);
use File::Spec::Functions qw(:ALL);
use Slim::Utils::Strings qw (string);
use Slim::Utils::Prefs;
use Slim::Utils::Misc;

my %current = ();

my %stations = (
	'radioio70s'  => '3765',			
	'radioio80s'  => '3795',
	'radioioACOUSTIC' => '3765',
    'radioioAMBIENT'  => '3605',
	'radioioBEAT' => '3725',
	'radioioCLASSICAL' => '3635',
	'radioioECLECTIC' => '3586',
	'radioioEDGE' => '3995',
	'radioioJAM' => '3970',
	'radioioJAZZ' => '3545',
	'radioioPOP' => '3965',
	'radioioROCK' => '3515',
);

my @station_names = sort keys %stations;

sub initPlugin {
	Slim::Player::Source::registerProtocolHandler("radioio", "Plugins::RadioIO::ProtocolHandler");
}

# Just so we don't have plain text URLs in the code.
sub decrypt {
	my $str = shift;
	
	$str =~ tr/a-zA-Z/n-za-mN-ZA-M/;
	$str =~ tr/0-9/5-90-4/;

	return $str;
}

sub getHTTPURL {
	my $key = shift;
	my $port = $stations{$key};
	my $url = "http://" . decrypt("enqvbvb.fp.yyajq.arg") . ":" .
		decrypt($port) . "/" . decrypt("yvfgra.cyf");
	return $url;
}

sub getRadioIOURL {
	my $num = shift;

	my $key = $station_names[$num];
	my $url = "radioio://" . $key . ".mp3";

	my %cacheEntry;
	$cacheEntry{'TITLE'} = $key;
	$cacheEntry{'CT'} = 'mp3';
	$cacheEntry{'VALID'} = 1;
	Slim::Music::Info::updateCacheEntry($url, \%cacheEntry);

	return $url;
}

my %functions = (
	'up' => sub {
		my $client = shift;
		$current{$client} =
		  Slim::Buttons::Common::scroll($client,
										-1,
										scalar(@station_names),
										$current{$client} || 0,
										);
		$client->update();
	},
	'down' => sub {
		my $client = shift;
		$current{$client} =
		  Slim::Buttons::Common::scroll($client,
										1,
										scalar(@station_names),
										$current{$client} || 0,
										);
		$client->update();
	},
	'left' => sub {
		my $client = shift;
		Slim::Buttons::Common::popModeRight($client);
	},
	'right' => sub {
		my $client = shift;
		$client->bumpRight();
	},
	'play' => sub {
		my $client = shift;

		my $url = getRadioIOURL($current{$client} || 0);

		if (defined($url)) {
			Slim::Control::Command::execute($client, ['playlist', 'clear']);
			Slim::Control::Command::execute($client, ['playlist', 'add', $url]);
			Slim::Control::Command::execute($client, ['play']);
		}
	},
	'add' => sub {
		my $client = shift;
		
		my $url = getRadioIOURL($current{$client} || 0);

		if (defined($url)) {
			Slim::Control::Command::execute($client, ['playlist', 'add', $url]);
		}
	},
);

sub lines {
	my $client = shift;
	my @lines;
	my $name = $station_names[$current{$client}];

	$lines[0] = Slim::Utils::Strings::string('PLUGIN_RADIOIO_MODULE_TITLE').
	    ' (' .
		($current{$client} + 1) .  ' ' .
		  Slim::Utils::Strings::string('OF') .  ' ' .
			  (scalar(@station_names)) .  ') ' ;
	$lines[1] = $name;
	$lines[3] = Slim::Display::Display::symbol('notesymbol');

	return @lines;
}

sub setMode() {
	my $client = shift;
	$current{$client} ||= 0;
	$client->lines(\&lines);
}

sub getFunctions() {
	return \%functions;
}

sub addMenu {
	my $menu = "RADIO";
	return $menu;
}

sub getDisplayName() { return string('PLUGIN_RADIOIO_MODULE_NAME') }

sub strings
{
	return "
PLUGIN_RADIOIO_MODULE_NAME
	EN	radioio.com - no boundaries.
	DE	radioio.com Internet Radio

PLUGIN_RADIOIO_MODULE_TITLE
	EN	radioio.com
	DE	radioio.com
";}

1;

package Plugins::RadioIO::ProtocolHandler;

use strict;

use vars qw(@ISA);

@ISA = qw(Slim::Player::Protocols::HTTP);

sub new {
	my $class = shift;
	my $url = shift;
	my $client = shift;

	if ($url =~ /^radioio:\/\/(.*?)\.mp3/) {
		my $pls = Plugins::RadioIO::getHTTPURL($1);
		my $sock = Slim::Player::Source::openRemoteStream($pls, $client);
		return undef if !defined($sock);
		
		my @items = Slim::Formats::Parse::parseList($pls, $sock);
		return undef if !scalar(@items);

		return $class->SUPER::new($items[0], $client, $url);
	}
	
	return undef;
}

1;


# Local Variables:
# tab-width:4
# indent-tabs-mode:t
# End:


    
