package Slim::Plugin::ExtendedBrowseModes::Plugin;

# Logitech Media Server Copyright 2001-2014 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;

use base qw(Slim::Plugin::OPMLBased);

use Slim::Menu::BrowseLibrary;
use Slim::Music::VirtualLibraries;
use Slim::Plugin::ExtendedBrowseModes::Libraries;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Text;

my $prefs = preferences('plugin.extendedbrowsemodes');
my $serverPrefs = preferences('server');

$prefs->init({
	additionalMenuItems => [{
		name    => string('PLUGIN_EXTENDED_BROWSEMODES_BROWSE_BY_COMPOSERS'),
		params  => { role_id => 'COMPOSER' },
		feed    => 'artists',
		id      => 'myMusicArtistsComposers',
		weight  => 12,
		enabled => 0,
	},{
		name    => 'Classical Music by Conductor',
		params  => { role_id => 'CONDUCTOR', genre_id => 'Classical' },
		feed    => 'artists',
		id      => 'myMusicArtistsConductors',
		weight  => 13,
		enabled => 0,
	},{
		name    => 'Jazz Composers',
		params  => { role_id => 'COMPOSER', genre_id => 'Jazz' },
		feed    => 'artists',
		id      => 'myMusicArtistsJazzComposers',
		weight  => 13,
		enabled => 0,
	},{
		name    => 'Audiobooks',
		params  => { genre_id => 'Audiobooks, Spoken, Speech' },
		feed    => 'albums',
		id      => 'myMusicAlbumsAudiobooks',
		weight  => 14,
		enabled => 0,
	}],
	enableLosslessPreferred => 0,
});

$prefs->setChange( \&initMenus, 'additionalMenuItems' );
Slim::Control::Request::subscribe( \&initMenus, [['library'], ['changed']] );
Slim::Control::Request::subscribe( \&initMenus, [['rescan'], ['done']] );

$prefs->setChange( sub {
	__PACKAGE__->initLibraries($_[1] || 0);
}, 'enableLosslessPreferred' );

sub initPlugin {
	my ( $class ) = @_;

	if ( main::WEBUI ) {
		require Slim::Plugin::ExtendedBrowseModes::Settings;
		require Slim::Plugin::ExtendedBrowseModes::PlayerSettings;
		Slim::Plugin::ExtendedBrowseModes::Settings->new;
		Slim::Plugin::ExtendedBrowseModes::PlayerSettings->new;
	}

	$class->initMenus();
	$class->initLibraries();
	
	$class->SUPER::initPlugin(
		feed   => \&handleFeed,
		tag    => 'selectVirtualLibrary',
		node   => 'myMusic',
		menu   => 'browse',
		weight => 100,
	);
}

sub handleFeed {
	my ($client, $cb, $args) = @_;

	my @items;
	my $libraries = Slim::Music::VirtualLibraries->getLibraries();
	while (my ($k, $v) = each %$libraries) {
		push @items, {
			name => $v->{name},
			url  => \&setLibrary,
			passthrough => [{
				library_id => $k,
			}],
			nextWindow => $args->{isControl} ? 'myMusic' : 'parent',
		};
	}

	# hard-coded item to reset the library view
	push @items, {
		name => cstring($client, 'PLUGIN_EXTENDED_BROWSEMODES_ALL_LIBRARY'),
		url  => \&setLibrary,
		passthrough => [{
			library_id => 0,
		}],
		nextWindow => $args->{isControl} ? 'myMusic' : 'parent',
	};

	$cb->({
		items => \@items,
	});
}

sub initLibraries {
	my ($class, $newValue) = @_;
	
	if ( defined $newValue && !$newValue ) {
		Slim::Music::VirtualLibraries->unregisterLibrary('losslessPreferred');
	}
	
	if ( $prefs->get('enableLosslessPreferred') ) {
		Slim::Plugin::ExtendedBrowseModes::Libraries->initLibraries();
		
		# if we were called on a onChange event, re-build the library
		Slim::Music::VirtualLibraries->rebuild('losslessPreferred') if $newValue;
	}
}

sub setLibrary {
	my ($client, $cb, $params, $args) = @_;

	if (!$client) {
		$cb->({
			items => [{
				name => string('NO_PLAYER_FOUND'),
			}]
		});
		return;
	}
	

	$serverPrefs->client($client)->set('libraryId', $args->{library_id});

	$serverPrefs->client($client)->remove('libraryId') unless $args->{library_id};

	$cb->({
		items => [{
			name => Slim::Music::VirtualLibraries->getNameForId($args->{library_id}) || cstring($client, 'PLUGIN_EXTENDED_BROWSEMODES_ALL_LIBRARY'),
			showBriefly => 1,
#			nextWindow => 'myMusic',
		}]
	});

	# pre-cache totals
	Slim::Utils::Timers::setTimer(__PACKAGE__, Time::HiRes::time() + 0.1, sub {
		Slim::Schema->totals($client);
	});
}

sub condition {
	my ($class, $client) = @_;
	
	return unless Slim::Music::VirtualLibraries->hasLibraries();
	
	return !$client || !$serverPrefs->client($_[1])->get('disabled_selectVirtualLibrary');
}

sub getDisplayName { 'PLUGIN_EXTENDED_BROWSEMODES_LIBRARIES' }

sub initMenus {
	# custom feed: we need to inject the latest VA ID
	my $compilationsMenu = {
		name         => 'PLUGIN_EXTENDED_BROWSEMODES_COMPILATIONS',
		params       => {
			mode => 'vaalbums',
			artist_id => Slim::Schema->variousArtistsObject->id,
		},
		feed         => 'albums',
		id           => 'myMusicAlbumsVariousArtists',
		weight       => 22,
	};

	foreach (@{$prefs->get('additionalMenuItems') || []}, $compilationsMenu) {
		__PACKAGE__->registerBrowseMode($_);
	}
}

sub registerBrowseMode {
	my ($class, $item) = @_;
	
	# create string token if it doesn't exist already
	my $nameToken = $class->registerCustomString($item->{name});

	# remove menu item before adding it back in - we might have changed its definition
	Slim::Menu::BrowseLibrary->deregisterNode($item->{id});

	foreach my $clientPref ( $serverPrefs->allClients ) {
		if ($item->{enabled}) {
			$clientPref->remove('disabled_' . $item->{id});
		}
		elsif (defined $item->{enabled}) {
			$clientPref->set('disabled_' . $item->{id}, 1);
		}
	}
	
	my $icon = $item->{icon};

	# replace feed placeholders
	my ($feed, $mode);
	if ( ref $item->{feed} eq 'CODE' ) {
		$feed = $item->{feed};
	}
	elsif ( $item->{feed} =~ /\balbums$/ ) {
		$feed = \&Slim::Menu::BrowseLibrary::_albums;
		$icon = 'html/images/albums.png';
		$mode = $item->{params}->{mode} || $item->{id};
	}
	else {
		$feed = \&Slim::Menu::BrowseLibrary::_artists;
		$icon = 'html/images/artists.png';
		$mode = $item->{params}->{mode} || $item->{id};
	}
	
	my %params = map {
		my $v = Slim::Plugin::ExtendedBrowseModes::Plugin->valueToId($item->{params}->{$_}, $_);
		{ $_ => $v };
	} keys %{ $item->{params} || {} };
	
	Slim::Menu::BrowseLibrary->registerNode({
		type         => 'link',
		name         => $nameToken,
		params       => \%params,
		feed         => $feed,
		icon         => $icon,
		jiveIcon     => $icon,
		homeMenuText => $nameToken,
		condition    => $item->{condition} || \&Slim::Menu::BrowseLibrary::isEnabledNode,
		id           => $item->{id},
		weight       => $item->{weight},
		cache        => $item->{nocache} ? 0 : 1,
	});
}

sub registerCustomString {
	my ($class, $string) = @_;
	
	if ( !Slim::Utils::Strings::stringExists($string) ) {
		my $token = Slim::Utils::Text::ignoreCaseArticles($string, 1);
		
		$token =~ s/\s/_/g;
		$token = 'PLUGIN_EXTENDED_BROWSEMODES_' . $token;
		 
		Slim::Utils::Strings::storeExtraStrings([{
			strings => { EN => $string},
			token   => $token,
		}]);

		return $token;
	}
	
	return $string;
}

# transform genre_id/artist_id into real IDs if a text is used (eg. "Various Artists")
sub valueToId {
	my ($class, $value, $key) = @_;
	
	if ($key eq 'role_id') {
		return join(',', grep {
			$_ !~ /\D/
		} map {
			s/^\s+|\s+$//g; 
			uc($_);
			Slim::Schema::Contributor->typeToRole($_);
		} split(/,/, $value) );
	}
	
	return (defined $value ? $value : 0) unless $value && $key =~ /^(genre|artist)_id/;
	
	my $category = $1;
	
	my $schema;
	if ($category eq 'genre') {
		$schema = 'Genre';
	}
	elsif ($category eq 'artist') {
		$schema = 'Contributor';
	}
	
	# replace names with IDs
	if ( $schema && Slim::Schema::hasLibrary() ) {
		$value = join(',', grep {
			$_ !~ /\D/
		} map {
			s/^\s+|\s+$//g; 

			$_ = Slim::Utils::Unicode::utf8decode_locale($_);
			$_ = Slim::Utils::Text::ignoreCaseArticles($_, 1);
			
			if ( !Slim::Schema->rs($schema)->find($_) && (my $item = Slim::Schema->rs($schema)->search({ 'namesearch' => $_ })->first) ) {
				$_ = $item->id;
			}
			
			$_;
		} split(/,/, $value) );
	}

	return $value || -1;
}	

1;