#!/usr/bin/env perl
use Mojolicious::Lite;
use Mojo::UserAgent;
use Net::Google::Spreadsheets;
use Regexp::Common qw /URI/;
use CHI;

my $config = plugin 'JSONConfig';

my $cache = CHI->new( driver => 'Memory', global => 1 );

# UserAgent
my $ua = Mojo::UserAgent->new;

# TODO change to ReadOnly
use constant REPRESENT_API => 'http://represent.opennorth.ca';
use constant TYEE_API      => 'http://api.thetyee.ca/v1/';

# Connect to Google Spreadsheets on app startup
my $service = Net::Google::Spreadsheets->new(
    username => $config->{'google_username'},
    password => $config->{'google_password'},
);

# Route requests to /
get '/' => sub {
    my $self = shift;

    # TODO move this to JS in front-page.js, no point here.
    # Get the latest The Hook items from the Tyee's API
    my $hook_posts = $cache->get( 'hook_posts' );
    if ( !defined $hook_posts ) {
        my $hook_json = $ua->get( TYEE_API . '/latest/blogs/' )->res->json;
        $hook_posts = $hook_json->{'hits'}{'hits'};
        $cache->set( 'hook_posts', $hook_posts, "5 minutes" );
    }
    my $poll = _get_poll();

    # Stash the data that we'll use in the index template
    $self->stash(
        hook_posts => $hook_posts,
        asset      => $config->{'static_asset_path'},
        poll       => $poll,
    );

    # Render the index.html.ep template
    $self->render( 'index' );
};

# Route requests to /riding/riding-name/
get '/riding/:name' => sub {
    my $self = shift;
    return $self->render_exception unless $service;

    # Store the riding name
    my $name = $self->stash( 'name' );

    # Find the corresponding row in the spreadsheet for the riding name
    # (get it from the cache, if possible)
    my $riding       = $cache->get( $name );
    my $cache_status = 'cached';
    if ( !defined $riding ) {
        $riding = _get_riding_from_gs( $name );

        # 404
        return $self->render_not_found
            unless $riding;

        $cache->set( $name, $riding, "30 minutes" );
        $cache_status = 'fetched';
    }
    $self->app->log->debug( "Cache status was: $cache_status" );

    # Find the corresponding row in the spreadsheet for the BC averages
    # (get it from the cache, if possible)
    my $avg_row_name = 'Averages';
    my $avg          = $cache->get( $avg_row_name );
    if ( !defined $avg ) {
        $avg = _get_avg_from_gs( $avg_row_name );
        $cache->set( $avg_row_name, $avg, "24 hours" );
    }

    # TODO First most to sub, then...
    # TODO move to JS in ridings.html.ep, just slowing things down
    # Get the incumbent photo and so on from Represent
    my $rep_data = $cache->get( $name . '-incumbent' );
    if ( !defined $rep_data ) {
        my $rep_query
            = '/boundaries/british-columbia-electoral-districts/'
            . $name
            . '/representatives/';
        $rep_data = $ua->get( REPRESENT_API . $rep_query )->res->json;
        $rep_data = $rep_data->{'objects'}[0];

        # TODO Party names in GS vs. Represent
        if ( $rep_data->{'party_name'} eq 'New Democratic Party of BC' ) {
            $rep_data->{'party_name'} = 'BC New Democratic Party';
        }
        $cache->set( $name . '-incumbent', $rep_data, "24 hours" );
    }

    # TODO this should probably get migrated to a Class
    my $parties      = _get_parties_from_gs();
    my $party_lookup = _get_party_lookup( $parties );

    # New approach to getting candidate data from GS
    my $candidates      = _get_candidates_from_gs( $name );
    my $candidate_names = _get_candidate_names( $candidates );
    my $poll            = _get_poll();

    # Stash the data from the spreadsheet for use in the template
    $self->stash(
        riding          => $riding,
        rep_data        => $rep_data,
        candidate_names => $candidate_names,
        bc_averages     => $avg,
        related_stories => _get_tyee_story_urls( $riding->{'tyee-stories'} ),
        cache_status    => $cache_status,
        asset           => $config->{'static_asset_path'},
        parties         => $parties,
        party_lookup    => $party_lookup,
        candidates      => $candidates,
        poll            => $poll,
    );

    # Render the riding.html.ep template
    $self->render( 'riding' );
};

# Route requests to /candidates
get '/candidates' => sub {
    my $self = shift;

    my ( $candidates, $cache_status ) = _get_candidates();
    $self->app->log->debug( "Cache status was: $cache_status" );
    my $parties      = _get_parties_from_gs();
    my $party_lookup = _get_party_lookup( $parties );
    my $stats        = _get_candidate_stats( $candidates, $parties );

    # Stash the data that we'll use in the index template
    $self->stash(
        candidates   => $candidates,
        cache_status => $cache_status,
        stats        => $stats,
        asset        => $config->{'static_asset_path'},
        parties      => $parties,
        party_lookup => $party_lookup,
    );

    # Render the index.html.ep template
    $self->render( 'candidates' );
};

# Route requests to /ridings
get '/ridings' => sub {
    my $self = shift;

    my ( $ridings, $cache_status ) = _get_riding_calls();
    $self->app->log->debug( "Cache status was: $cache_status" );
    my $parties      = _get_parties_from_gs();
    my $party_lookup = _get_party_lookup( $parties );
    my $stats        = _get_riding_call_stats ( $ridings, $parties );
    # Stash the data that we'll use in the index template
    $self->stash(
        ridings      => $ridings,
        cache_status => $cache_status,
        asset        => $config->{'static_asset_path'},
        parties      => $parties,
        party_lookup => $party_lookup,
        stats        => $stats,
    );

    # Render the index.html.ep template
    $self->render( 'ridings' );
};
########################################################################
# Sub-routines
########################################################################
sub _get_tyee_story_urls {
    my $string = shift;
    my @related_stories = $string =~ /(?'url'$RE{URI}{HTTP})/g;
    my @stories;
    for my $s ( @related_stories ) {
        my $path = $s;
        $path =~ s!http://thetyee\.ca!!;
        push @stories, $path;
    }
    return \@stories;
}

sub _get_riding_from_gs {
    my ( $name ) = @_;

    # Find the spreadsheet by key
    my $spreadsheet
        = $service->spreadsheet( { key => $config->{'spreadsheet_key'}, } );

    # Find the main worksheet by title
    my $worksheet = $spreadsheet->worksheet(
        { title => $config->{'worksheet_name'}, } );

    my $row = $worksheet->row( { sq => 'slug = "' . $name . '"' } );
    my $riding = {};
    $riding = $row->{'content'};

    return $riding;
}

sub _get_parties_from_gs {

    # Find the spreadsheet by key
    my $spreadsheet
        = $service->spreadsheet( { key => $config->{'spreadsheet_key'}, } );

    # Find the main worksheet by title
    my $worksheet = $spreadsheet->worksheet(
        { title => $config->{'worksheet_name_parties'}, } );

    my @rows = $worksheet->rows();

    #$riding = $row->{'content'};
    my $parties = {};
    for my $party ( @rows ) {
        my $slug = $party->content->{'slug'};
        $parties->{$slug} = $party->content;
    }
    return $parties;
}

sub _get_party_lookup {
    my ( $parties ) = @_;
    my $party_lookup = {};
    for my $party ( sort keys $parties ) {
        $party_lookup->{ $parties->{$party}{'shortname'} }
            = $parties->{$party}->{'slug'};
    }
    return $party_lookup;
}

sub _get_candidates_from_gs {

    # TODO Return an array here instead
    # TODO Do the caching here also
    my ( $name ) = @_;

    # Find the spreadsheet by key
    my $spreadsheet
        = $service->spreadsheet( { key => $config->{'spreadsheet_key'}, } );

    # Find the main worksheet by title
    my $worksheet = $spreadsheet->worksheet(
        { title => $config->{'worksheet_name_candidates'}, } );
    my @rows;
    if ( $name ) {    # Get only the rows matching the riding name
        @rows = $worksheet->rows( { sq => 'slug = "' . $name . '"' } );
    }
    else {            # Get all the rows / candidates
        @rows = $worksheet->rows;
    }
    my $candidates = {};
    for my $candidate ( @rows ) {
        my $slug = lc( $candidate->content->{'lastname'} );
        $candidate->content->{'twitter'} =~ s/@//g;
        $slug =~ s/\W/-/g;
        $candidates->{$slug} = $candidate->content;
    }
    return $candidates;
}

sub _get_candidates {

    #my $candidates   = $cache->get( 'candidates' );
    my $candidates;
    my $cache_status = 'cached';
    if ( !defined $candidates ) {

        # Find the spreadsheet by key
        my $spreadsheet = $service->spreadsheet(
            { key => $config->{'spreadsheet_key'}, } );

        # Find the main worksheet by title
        my $worksheet = $spreadsheet->worksheet(
            { title => $config->{'worksheet_name_candidates'}, } );
        my @rows = $worksheet->rows;
        $candidates = [];
        for my $candidate ( @rows ) {
            $candidate->content->{'twitter'} =~ s/@//g;
            push @$candidates, $candidate->content;
        }

        @$candidates
            = sort { $a->{'riding'} cmp $b->{'riding'} } @$candidates;
        $cache->set( 'candidates', $candidates, "30 minutes" );
        $cache_status = 'fetched';
    }
    return $candidates, $cache_status;
}

sub _get_riding_calls {

    my $ridings;
    my $cache_status = 'cached';
    if ( !defined $ridings ) {

        # Find the spreadsheet by key
        my $spreadsheet = $service->spreadsheet(
            { key => $config->{'spreadsheet_key'}, } );

        # Find the main worksheet by title
        my $worksheet = $spreadsheet->worksheet(
            { title => $config->{'worksheet_name_ridings'}, } );
        my @rows = $worksheet->rows;
        $ridings = [];
        for my $riding ( @rows ) {
            push @$ridings, $riding->content;
        }

        @$ridings
            = sort { $a->{'key'} cmp $b->{'key'} } @$ridings;
        $cache->set( 'ridings', $ridings, "30 minutes" );
        $cache_status = 'fetched';
    }
    return $ridings, $cache_status;
}

sub _get_candidate_names {
    my ( $candidates ) = @_;
    my @candidate_names;
    my $can_names_str;
    for my $key ( sort keys $candidates ) {
        my $can = $candidates->{$key};
        push @candidate_names, $can->{'fullname'};
    }
    my $candidate_last = pop @candidate_names;
    if ( @candidate_names == 1 ) {
        $can_names_str = $candidate_names[0] . ' and ' . $candidate_last;
    }
    elsif ( @candidate_names > 1 ) {
        $can_names_str = join( ', ', @candidate_names );
        $can_names_str .= ', and ' . $candidate_last;
    }
    else {
        $can_names_str = $candidate_last;
    }
    return $can_names_str;
}

sub _get_avg_from_gs {
    my ( $avg_row ) = @_;

    # Find the spreadsheet by key
    my $spreadsheet
        = $service->spreadsheet( { key => $config->{'spreadsheet_key'}, } );

    # Find the main worksheet by title
    my $worksheet = $spreadsheet->worksheet(
        { title => $config->{'worksheet_name'}, } );

    my $row = $worksheet->row( { sq => 'ridingcode = "' . $avg_row . '"' } );

    my $avg = $row->{'content'};

    return $avg;
}

sub _get_candidate_stats {
    my ( $candidates, $parties ) = @_;
    my $stats = {};
    for my $party ( keys $parties ) {
        my $p = $parties->{$party};
        $stats->{ $p->{'slug'} } = {
            incumbents => 0,
            men        => 0,
            num        => 0,
            women      => 0,
        };
    }
    for my $can ( @$candidates ) {
        for my $party ( keys $parties ) {
            my $p = $parties->{$party};
            if ( $can->{'party'} eq $p->{'officialname'} ) {
                $stats->{ $p->{'slug'} }{'num'}++;
                if ( $can->{'gender'} eq 'f' ) {
                    $stats->{ $p->{'slug'} }{'women'}++;
                    $stats->{'women'}++;
                }
                elsif ( $can->{'gender'} eq 'm' ) {
                    $stats->{ $p->{'slug'} }{'men'}++;
                    $stats->{'men'}++;
                }
                if ( $can->{'incumbent'} eq 'yes' ) {
                    $stats->{ $p->{'slug'} }{'incumbents'}++;
                    $stats->{'incumbents'}++;
                }
            }
        }
    }
    return $stats;
}    ## --- end sub _get_candidates

sub _get_riding_call_stats {
    my ( $ridings, $parties ) = @_;
    my $stats = {};
    for my $r ( @$ridings ) {
        for ( $r->{'call'} ) {
            when ( /Too close to call/ ) { 
                $stats->{'ridings'}{'tooclose'}++;
            }
            when ( /Likely/ ) { 
                $stats->{'ridings'}{'likely'}++;
                $stats->{'parties'}{ $r->{'partyslug'} }{'likely'}++;
                $stats->{'parties'}{ $r->{'partyslug'} }{'total'}++;
            }
            when ( /Definitely/) { 
                $stats->{'ridings'}{'definitely'}++;
                $stats->{'parties'}{ $r->{'partyslug'} }{'definitely'}++;
                $stats->{'parties'}{ $r->{'partyslug'} }{'total'}++;
            }
        }
    }
    return $stats;
}

sub _get_poll {
    my $poll_html
        = $ua->get( $config->{'remote_inc_path'} . '/Polls/include.php' )
        ->res->body;

    # TODO make sure there's no error
    # TODO cache this!
    return $poll_html;
}

########################################################################
# For development, or deployment with Plack
########################################################################
#use Plack::Builder;
#builder {
## Only show the debug panel in development mode
#my $mode = app->mode;
#unless ( $mode eq 'production' ) {
#enable 'Debug';
#}
#app->secret( $config->{'app_secret'} );
#app->start;
#};

########################################################################
# For deployment with Morbo or Hypnotoad
########################################################################
app->secret( $config->{'app_secret'} );
app->start;
