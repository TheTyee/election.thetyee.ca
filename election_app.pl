#!/usr/bin/env perl
use Mojolicious::Lite;
use Mojo::UserAgent;
use Net::Google::Spreadsheets;
use Regexp::Common qw /URI/;
use utf8::all;
use CHI;

my $config = plugin 'JSONConfig';

#my $cache = CHI->new( driver => 'Memory', global => 1 );

my $cache = CHI->new(
    driver     => 'FastMmap',
    root_dir   => $config->{'cache_name'},
    cache_size => '50m',
    page_size  => '5026k',
);

# Route requests to / 
get '/' => sub {
    my $self = shift;
    my $hook_posts  = $cache->get( 'HookPostsNew' );
    my $poll        = $cache->get( 'poll' );
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
    my $name            = $self->stash( 'name' );
    my $riding          = $cache->get( $name );
    my $avg             = $cache->get( 'Averages' );
    my $rep_data        = $cache->get( $name . '-incumbent' );
    my $parties         = $cache->get( 'Parties' );
    my $party_lookup    = $cache->get( 'PartyLookup' );
    my $candidates      = $cache->get( $name . '-candidates' );
    use Data::Dumper;
    app->log->debug("test");
    app->log->debug("candidates \n" . Dumper($candidates) );
    my $candidate_names = _get_candidate_names( $candidates );
    my $riding_calls    = $cache->get( $name . '-calls' );
    my $poll            = $cache->get( 'poll' );
    my $votes           = $cache->get( $name . '-votes' );
    my $ebc_lookup      = $cache->get( 'ebclookup2' );
    # Stash the data 
    $self->stash(
        riding          => $riding,
        rep_data        => $rep_data,
        candidate_names => $candidate_names,
        bc_averages     => $avg,
        related_stories => _get_tyee_story_urls( $riding->{'tyee-stories'} ),
        cache_status    => 'Fetched',
        asset           => $config->{'static_asset_path'},
        parties         => $parties,
        party_lookup    => $party_lookup,
        candidates      => $candidates,
        poll            => $poll,
        call            => $riding_calls,
        ebc             => $votes,
        ebc_lookup      => $ebc_lookup,
    );
    # Render the riding.html.ep template
    $self->render( 'riding' );
};

# Route requests to /candidates
get '/candidates' => sub {
    my $self = shift;
    my $candidates      = $cache->get( 'candidates' );
    my $parties         = $cache->get( 'Parties' );
    my $party_lookup    = $cache->get( 'PartyLookup' );
    my $stats           = _get_candidate_stats( $candidates, $parties );
    # Stash the data
    $self->stash(
        candidates   => $candidates,
        cache_status => '',
        stats        => $stats,
        asset        => $config->{'static_asset_path'},
        parties      => $parties,
        party_lookup => $party_lookup,
    );
    # Render the candidates.html.ep template
    $self->render( 'candidates' );
};

# Route requests to /ridings
get '/ridings' => sub {
    my $self = shift;
    my $ridings      = $cache->get( 'ridings' );
    my $parties      = $cache->get( 'Parties' );;
    my $party_lookup    = $cache->get( 'PartyLookup' );
    my $stats        = _get_riding_call_stats ( $ridings, $parties );
    # Stash the data that we'll use in the index template
    $self->stash(
        ridings      => $ridings,
        cache_status => '',
        asset        => $config->{'static_asset_path'},
        parties      => $parties,
        party_lookup => $party_lookup,
        stats        => $stats,
    );
    # Render the ridings.html.ep template
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

sub _get_candidate_names {
    my ( $candidates ) = @_;
    my @candidate_names;
        if (!($candidates)) { return ''};
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

########################################################################
# For development, or deployment with Plack
########################################################################
 #use Plack::Builder;
# builder {
## Only show the debug panel in development mode
# my $mode = app->mode;
# unless ( $mode eq 'production' ) {
# enable 'Debug';
 #}
# app->secret( $config->{'app_secret'} );
#app->start;
#  };

########################################################################
# For deployment with Morbo or Hypnotoad
########################################################################
app->secret( $config->{'app_secret'} );
 app->start;
