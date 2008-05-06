package Slim::Web::XMLBrowser;

# $Id$

# SqueezeCenter Copyright 2001-2007 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License, 
# version 2.

# This class displays a generic web interface for XML feeds

use strict;

use URI::Escape qw(uri_unescape);

use Slim::Formats::XML;
use Slim::Player::ProtocolHandlers;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Favorites;
use Slim::Web::HTTP;
use Slim::Web::Pages;

my $log = logger('formats.xml');

sub handleWebIndex {
	my ( $class, $args ) = @_;

	my $client    = $args->{'client'};
	my $feed      = $args->{'feed'};
	my $path      = $args->{'path'} || 'index.html';
	my $title     = $args->{'title'};
	my $search    = $args->{'search'};
	my $expires   = $args->{'expires'};
	my $timeout   = $args->{'timeout'};
	my $asyncArgs = $args->{'args'};
	my $item      = $args->{'item'} || {};
	my $pageicon  = $Slim::Web::Pages::additionalLinks{icons}{$title};
	
	# If the feed is already XML data (Podcast List), send it to handleFeed
	if ( ref $feed eq 'HASH' ) {

		handleFeed( $feed, {
			'url'     => $feed->{'url'},
			'path'    => $path,
			'title'   => $title,
			'search'  => $search,
			'expires' => $expires,
			'args'    => $asyncArgs,
			'pageicon'=> $pageicon
		} );

		return;
	}
	
	# Handle plugins that want to use callbacks to fetch their own URLs
	if ( ref $feed eq 'CODE' ) {
		# get passthrough params if supplied
		my $pt = $item->{'passthrough'} || [];
		
		# Passthrough all our web params
		push @{$pt}, $asyncArgs;
		
		# first param is a $client object, but undef from webpages
		$feed->( undef, \&handleFeed, @{$pt} );
		return;
	}

	# Handle search queries
	if ( my $query = $asyncArgs->[1]->{'query'} ) {

		$log->info("Search query [$query]");

		Slim::Formats::XML->openSearch(
			\&handleFeed,
			\&handleError,
			{
				'search' => $search,
				'query'  => $query,
				'title'  => $title,
				'args'   => $asyncArgs,
				'pageicon'=> $pageicon
			},
		);

		return;
	}

	# fetch the remote content
	Slim::Formats::XML->getFeedAsync(
		\&handleFeed,
		\&handleError,
		{
			'client'  => $client,
			'url'     => $feed,
			'path'    => $path,
			'title'   => $title,
			'search'  => $search,
			'expires' => $expires,
			'timeout' => $timeout,
			'args'    => $asyncArgs,
			'pageicon'=> $pageicon
		},
	);

	return;
}

sub handleFeed {
	my ( $feed, $params ) = @_;
	my ( $client, $stash, $callback, $httpClient, $response ) = @{ $params->{'args'} };

	$stash->{'pagetitle'} = $feed->{'title'} || string($params->{'title'});
	$stash->{'pageicon'}  = $params->{pageicon};

	my $template = 'xmlbrowser.html';
	
	# breadcrumb
	my @crumb = ( {
		'name'  => $feed->{'title'} || string($params->{'title'}),
		'index' => undef,
	} );
		
	# select the proper list of items
	my @index = ();

	if (defined $stash->{'index'}) {

		@index = split /\./, $stash->{'index'};
	}

	# favorites class to allow add/del of urls to favorites, but not when browsing favorites list itself
	my $favs = Slim::Utils::Favorites->new($client) unless $feed->{'favorites'};
	my $favsItem;

	# action is add/delete favorite: pop the last item off the index as we want to display the whole page not the item
	# keep item id in $favsItem so we can process it later
	if ($stash->{'action'} && $stash->{'action'} =~ /^(favadd|favdel)$/ && @index) {
		$favsItem = pop @index;
	}

	if ( my $levels = scalar @index ) {
		
		# index links for each crumb item
		my @crumbIndex = ();
		
		# descend to the selected item
		my $depth = 0;
		
		my $subFeed = $feed;
		for my $i ( @index ) {
			$depth++;
			
			$subFeed = $subFeed->{'items'}->[$i];
			
			push @crumbIndex, $i;
			my $crumbText = join '.', @crumbIndex;
			
			# Add search query to crumb list
			if ( $subFeed->{'type'} && $subFeed->{'type'} eq 'search' && $stash->{'q'} ) {
				$crumbText .= '_' . $stash->{'q'};
			}
			
			push @crumb, {
				'name'  => $subFeed->{'name'} || $subFeed->{'title'},
				'index' => $crumbText,
			};

			# Change type to audio if it's an action request and we have a play attribute
			# and it's the last item
			if ( 
				   $subFeed->{'play'} 
				&& $depth == $levels
				&& $stash->{'action'} =~ /^(?:play|add)$/
			) {
				$subFeed->{'type'} = 'audio';
			}
			
			# Change URL if there is a playlist attribute and it's the last item
			if ( 
			       $subFeed->{'playlist'}
				&& $depth == $levels
				&& $stash->{'action'} =~ /^(?:playall|addall)$/
			) {
				$subFeed->{'type'} = 'playlist';
				$subFeed->{'url'}  = $subFeed->{'playlist'};
			}
			
			# If the feed is another URL, fetch it and insert it into the
			# current cached feed
			$subFeed->{'type'} ||= '';
			if ( $subFeed->{'type'} ne 'audio' && defined $subFeed->{'url'} && !$subFeed->{'fetched'} ) {
				
				my $searchQuery;
				if ( $i =~ /\d+_(.+)/ ) {
					$searchQuery = $1;
				}
				
				# Rewrite the URL if it was a search request
				if ( $subFeed->{'type'} eq 'search' && ( $stash->{'q'} || $searchQuery ) ) {
					my $search = $stash->{'q'} || $searchQuery;
					$subFeed->{'url'} =~ s/{QUERY}/$search/g;
				}
				
				# Setup passthrough args
				my $args = {
					'client'       => $client,
					'item'         => $subFeed,
					'url'          => $subFeed->{'url'},
					'path'         => $params->{'path'},
					'feedTitle'    => $subFeed->{'name'} || $subFeed->{'title'},
					'parser'       => $subFeed->{'parser'},
					'expires'      => $params->{'expires'},
					'timeout'      => $params->{'timeout'},
					'parent'       => $feed,
					'parentURL'    => $params->{'parentURL'} || $params->{'url'},
					'currentIndex' => \@crumbIndex,
					'args'         => [ $client, $stash, $callback, $httpClient, $response ],
					'pageicon'     => $params->{'pageicon'}
				};
				
				if ( ref $subFeed->{'url'} eq 'CODE' ) {
					my $pt = $subFeed->{'passthrough'} || [];
					push @{$pt}, $args;
					$subFeed->{'url'}->( undef, \&handleSubFeed, @{$pt} );
					return;
				}
				
				# Check for a cached version of this subfeed URL
				if ( my $cached = Slim::Formats::XML->getCachedFeed( $subFeed->{'url'} ) ) {
					$log->debug( "Using previously cached subfeed data for $subFeed->{url}" );
					handleSubFeed( $cached, $args );
				}
				else {
					# We need to fetch the URL
					Slim::Formats::XML->getFeedAsync(
						\&handleSubFeed,
						\&handleError,
						$args,
					);
				}
				
				return;
			}
		}
			
		# If the feed contains no sub-items, display item details
		if ( !$subFeed->{'items'} 
			 ||
			 ( ref $subFeed->{'items'} eq 'ARRAY' && !scalar @{ $subFeed->{'items'} } ) 
		) {
			$subFeed->{'image'} = $subFeed->{'image'} || Slim::Player::ProtocolHandlers->iconForURL($subFeed->{'play'} || $subFeed->{'url'});

			$stash->{'streaminfo'} = {
				'item'  => $subFeed,
				'index' => join '.', @index,
			};
		}
		
		# Construct index param for each item in the list
		my $itemIndex = join( '.', @index );
		if ( $stash->{'q'} ) {
			$itemIndex .= '_' . $stash->{'q'};
		}
		$itemIndex .= '.';
		
		$stash->{'pagetitle'} = $subFeed->{'name'} || $subFeed->{'title'};
		$stash->{'crumb'}     = \@crumb;
		$stash->{'items'}     = $subFeed->{'items'};
		$stash->{'index'}     = $itemIndex;
		$stash->{'image'}     = $subFeed->{'image'};
	}
	else {
		$stash->{'pagetitle'} = $feed->{'title'} || string($params->{'title'});
		$stash->{'crumb'}     = \@crumb;
		$stash->{'items'}     = $feed->{'items'};
		
		# insert a search box on the top-level page if we support searching
		# for this feed
		if ( $params->{'search'} ) {
			$stash->{'search'} = 1;
		}

		if (defined $favsItem) {
			$stash->{'index'} = undef;
		}
	}
	
	# play/add stream
	if ( $client && $stash->{'action'} && $stash->{'action'} =~ /^(play|add)$/ ) {
		my $play  = ($stash->{'action'} eq 'play');
		my $url   = $stash->{'streaminfo'}->{'item'}->{'url'};
		my $title = $stash->{'streaminfo'}->{'item'}->{'name'} 
			|| $stash->{'streaminfo'}->{'item'}->{'title'};
		
		# Podcast enclosures
		if ( my $enc = $stash->{'streaminfo'}->{'item'}->{'enclosure'} ) {
			$url = $enc->{'url'};
		}
		
		# Items with a 'play' attribute will use this for playback
		if ( my $play = $stash->{'streaminfo'}->{'item'}->{'play'} ) {
			$url = $play;
		}
		
		if ( $url ) {

			$log->info("Playing/adding $url");
			
			# Set metadata about this URL
			Slim::Music::Info::setRemoteMetadata( $url, {
				title   => $title,
				ct      => $stash->{'streaminfo'}->{'item'}->{'mime'},
				secs    => $stash->{'streaminfo'}->{'item'}->{'duration'},
				bitrate => $stash->{'streaminfo'}->{'item'}->{'bitrate'},
			} );
		
			if ( $play ) {
				$client->execute([ 'playlist', 'clear' ]);
				$client->execute([ 'playlist', 'play', $url ]);
			}
			else {
				$client->execute([ 'playlist', 'add', $url ]);
			}
		
			my $webroot = $stash->{'webroot'};
			$webroot =~ s/(.*?)plugins.*$/$1/;
			$template = 'xmlbrowser_redirect.html';
		}
	}
	# play all/add all
	elsif ( $client && $stash->{'action'} && $stash->{'action'} =~ /^(playall|addall)$/ ) {
		my $play  = ($stash->{'action'} eq 'playall');
		
		my @urls;
		# XXX: Why is $stash->{streaminfo}->{item} added on here, it seems to be undef?
		for my $item ( @{ $stash->{'items'} }, $stash->{'streaminfo'}->{'item'} ) {
			my $url;
			if ( $item->{'type'} eq 'audio' && $item->{'url'} ) {
				$url = $item->{'url'};
			}
			elsif ( $item->{'enclosure'} && $item->{'enclosure'}->{'url'} ) {
				$url = $item->{'enclosure'}->{'url'};
			}
			elsif ( $item->{'play'} ) {
				$url = $item->{'play'};
			}
			
			next if !$url;
			
			# Set metadata about this URL
			Slim::Music::Info::setRemoteMetadata( $url, {
				title   => $item->{'name'} || $item->{'title'},
				ct      => $item->{'mime'},
				secs    => $item->{'duration'},
				bitrate => $item->{'bitrate'},
			} );
			
			main::idleStreams();
			
			push @urls, $url;
		}
		
		if ( @urls ) {

			if ( $log->is_info ) {
				$log->info(sprintf("Playing/adding all items:\n%s", join("\n", @urls)));
			}
			
			if ( $play ) {
				$client->execute([ 'playlist', 'play', \@urls ]);
			}
			else {
				$client->execute([ 'playlist', 'add', \@urls ]);
			}

			my $webroot = $stash->{'webroot'};
			$webroot =~ s/(.*?)plugins.*$/$1/;
			$template = 'xmlbrowser_redirect.html';
		}
	}
	else {
		
		# Check if any of our items contain audio as well as a duration value, so we can display an
		# 'All Songs' link.  Lists with no duration values are lists of radio stations where it doesn't
		# make sense to have an All Songs link. (bug 6531)
		for my $item ( @{ $stash->{'items'} } ) {
			next unless ( $item->{'type'} && $item->{'type'} eq 'audio' ) || $item->{'enclosure'} || $item->{'play'};
			next unless defined $item->{'duration'};

			$stash->{'itemsHaveAudio'} = 1;
			$stash->{'currentIndex'}   = join '.', @index;
			last;
		}
		
		my $itemCount = scalar @{ $stash->{'items'} };
		
		my $clientId = ( $client ) ? $client->id : undef;
		my $otherParams = '&index=' . $crumb[-1]->{index} . '&player=' . $clientId;
		if ( $stash->{'query'} ) {
			$otherParams = '&query=' . $stash->{'query'} . $otherParams;
		}
			
		$stash->{'pageinfo'} = Slim::Web::Pages->pageInfo({
				'itemCount'   => $itemCount,
				'path'        => $params->{'path'} || 'index.html',
				'otherParams' => $otherParams,
				'start'       => $stash->{'start'},
				'perPage'     => $stash->{'itemsPerPage'},
		});
		
		$stash->{'start'} = $stash->{'pageinfo'}{'startitem'};
		
		$stash->{'path'} = $params->{'path'} || 'index.html';

		if ($stash->{'pageinfo'}{'totalpages'} > 1) {

			# the following ensures the original array is not altered by creating a slice to show this page only
			my $start = $stash->{'start'};
			my $finish = $start + $stash->{'pageinfo'}{'itemsperpage'};
			$finish = $itemCount if ($itemCount < $finish);

			my @items = @{ $stash->{'items'} };
			my @slice = @items [ $start .. $finish - 1 ];
			$stash->{'items'} = \@slice;
		}
	}

	if ($favs) {
		my @items = @{$stash->{'items'} || []};
		my $start = $stash->{'start'} || 0;

		if (defined $favsItem && $items[$favsItem - $start]) {
			my $item = $items[$favsItem - $start];
			if ($stash->{'action'} eq 'favadd') {

				my $type = $item->{'type'} || 'link';
				
				if ( $item->{'play'} ) {
					$type = 'audio';
				}

				$favs->add(
					$item->{'play'} || $item->{'url'},
					$item->{'name'}, 
					$type, 
					$item->{'parser'}, 
					undef, 
					$item->{'image'} || Slim::Player::ProtocolHandlers->iconForURL($item->{'play'} || $item->{'url'}) 
				);
			} elsif ($stash->{'action'} eq 'favdel') {
				$favs->deleteUrl( $item->{'play'} || $item->{'url'} );
			}
		}
	
		for my $item (@items) {
			if ($item->{'url'}) {
				$item->{'favorites'} = $favs->hasUrl( $item->{'play'} || $item->{'url'} ) ? 2 : 1;
			}
		}
	}

	my $output = processTemplate($template, $stash);
	
	# done, send output back to Web module for display
	$callback->( $client, $stash, $output, $httpClient, $response );
}

sub handleError {
	my ( $error, $params ) = @_;
	my ( $client, $stash, $callback, $httpClient, $response ) = @{ $params->{'args'} };
	
	my $template = 'xmlbrowser.html';
	
	my $title = string($params->{'title'});
	$stash->{'pagetitle'} = $title;
	$stash->{'pageicon'}  = $params->{pageicon};
	$stash->{'msg'} = sprintf(string('WEB_XML_ERROR'), $title, $error);
	
	my $output = processTemplate($template, $stash);
	
	# done, send output back to Web module for display
	$callback->( $client, $stash, $output, $httpClient, $response );
}

# Fetch a feed URL that is referenced within another feed.
# After fetching, insert the contents into the original feed
sub handleSubFeed {
	my ( $feed, $params ) = @_;
	my ( $client, $stash, $callback, $httpClient, $response ) = @{ $params->{'args'} };
	
	# If there's a command we need to run, run it.  This is used in various
	# places to trigger actions from an OPML result, such as to start playing
	# a new Pandora radio station
	if ( $feed->{'command'} && $client ) {
		my @p = map { uri_unescape($_) } split / /, $feed->{command};
		$log->is_debug && $log->debug( "Executing command: " . Data::Dump::dump(\@p) );
		$client->execute( \@p );
	}
	
	# find insertion point for sub-feed data in the original feed
	my $parent = $params->{'parent'};
	my $subFeed = $parent;
	for my $i ( @{ $params->{'currentIndex'} } ) {
		$subFeed = $subFeed->{'items'}->[$i];
	}

	if ($subFeed->{'type'} && 
		($subFeed->{'type'} eq 'replace' || 
		 ($subFeed->{'type'} eq 'playlist' && $subFeed->{'parser'} && scalar @{ $feed->{'items'} } == 1) ) ) {
		# in the case of a replace entry or playlist of one with parser update previous entry to avoid adding a new menu level
		my $item = $feed->{'items'}[0];
		if ($subFeed->{'type'} eq 'replace') {
			delete $subFeed->{'url'};
		}
		for my $key (keys %$item) {
			$subFeed->{ $key } = $item->{ $key };
		}
	} else {
		# otherwise insert items as subfeed
		$subFeed->{'items'} = $feed->{'items'};
		
		# Update the title value in case it's different from the previous menu
		if ( $feed->{'title'} ) {
			$subFeed->{'name'} = $feed->{'title'};
		}
	}

	# set flag to avoid fetching this url again
	$subFeed->{'fetched'} = 1;

	# No caching for callback-based plugins
	# XXX: this is a bit slow as it has to re-fetch each level
	if ( ref $subFeed->{'url'} eq 'CODE' ) {
		
		# Clear passthrough data as it won't be needed again
		delete $subFeed->{'passthrough'};
	}
	
	handleFeed( $parent, $params );
}

sub processTemplate {
	return Slim::Web::HTTP::filltemplatefile( @_ );
}

1;
