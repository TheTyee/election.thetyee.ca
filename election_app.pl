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
        my $hook_json  = $ua->get( TYEE_API . '/latest/blogs/' )->res->json;
        $hook_posts = $hook_json->{'hits'}{'hits'};
        $cache->set( 'hook_posts', $hook_posts, "5 minutes" );
    }

    # Stash the data that we'll use in the index template
    $self->stash(
        hook_posts => $hook_posts,
        asset      => $config->{'static_asset_path'},
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

        $cache->set( $name, $riding, "5 minutes" );
        $cache_status = 'fetched';
    }
    $self->app->log->debug( "Cache status was: $cache_status" );

    # Find the corresponding row in the spreadsheet for the BC averages
    # (get it from the cache, if possible)
    my $avg_row_name = 'Averages';
    my $avg          = $cache->get( $avg_row_name );
    if ( !defined $avg ) {
        $avg = _get_avg_from_gs( $avg_row_name );
        $cache->set( $avg_row_name, $avg, "240 minutes" );
    }

    # TODO move to sub
    # Handle data issues with the incumbent column
    my $incumbent = $riding->{'incumbent'};
    $incumbent =~ s/\s*$//g
        if $incumbent;    # Remove any trailing whitespace in spreadsheet

    # TODO move to JS in ridings.html.ep, just slowing things down
    # Get the incumbent photo and so on from Represent
    my $rep_data = $cache->get( $incumbent );
    if ( !defined $rep_data ) {
        my $rep_query = '/representatives/?name=' . $incumbent;
        $rep_data  = $ua->get( REPRESENT_API . $rep_query )->res->json;
        $cache->set( $incumbent, $rep_data, "240 minutes" );
    }

    # Get rid of 'BC ' at the start of party names
    my $party = $riding->{'incumbentparty'};
    # TODO this should probably get migrated to a Class
    my $parties = {
        bcliberal      => { 
            name        => 'BC Liberal',
            url         => 'http://www.bcliberals.com/',
            css         => 'liberal',
            facebook    => '',
            twitter     => '',
            hashtag     => '',
        },
        bcndp           => {
            name  => 'BC NDP',
            url   => 'http://www.bcndp.ca/',
            css         => 'ndp',
            facebook    => '',
            twitter     => '',
            hashtag     => '',
        },
        bcgreen        => { 
            name  => 'BC Green',
            url   => 'http://www.greenparty.bc.ca/',
            css   => 'green',
            facebook    => '',
            twitter     => '',
            hashtag     => '',
        },
        bcconservative => { 
            name  => 'BC Conservative',
            url   => 'http://www.bcconservative.ca/',
            css   => 'conservative',
            facebook    => '',
            twitter     => '',
            hashtag     => '',
        }
    };

    # TODO move to sub
    my $candidates = {};    # Let's pass the registered candidates in one go
    my @candidate_names;    # A list for page titles
    for my $p ( qw/ bcconservative bcgreen bcliberal bcndp other / ) {

      # Format Twitter handles consistently, regardless of how they're entered
        my $tw_username = $riding->{ $p . 'twitter' };
        $tw_username =~ s/@//gi if $tw_username;
        if ( $riding->{$p} ) {    # If there's a candidate
            push @candidate_names, $riding->{$p};
        }
        $candidates->{$p} = {
            name        => $riding->{$p},
            url         => $riding->{ $p . 'url' },
            twitter     => $tw_username,
            party       => $riding->{ $p . 'party' } || $parties->{ $p }{'name'},
        };
    }

    my $can_names;
    my $candidate_last = pop @candidate_names;
    if ( @candidate_names == 1 ) {
        $can_names = $candidate_names[0] . ' and ' . $candidate_last;
    } elsif ( @candidate_names > 1 ) {
        $can_names = join( ', ', @candidate_names );
        $can_names .= ', and ' . $candidate_last;
    } else {
        $can_names = $candidate_last;
    }

    # Stash the data from the spreadsheet for use in the template
    $self->stash(
        riding         => $riding,
        incumbent_name => $incumbent,
        rep_data       => $rep_data->{'objects'}[0],

        #rep_query       => REPRESENT_API . $rep_query,
        incumbent_party => $party,
        candidate_data  => $candidates,
        candidate_names => $can_names,
        bc_averages     => $avg,
        related_stories => _get_tyee_story_urls( $riding->{'tyee-stories'} ),
        cache_status    => $cache_status,
        asset           => $config->{'static_asset_path'},
        parties           => $parties,
    );

    # Render the riding.html.ep template
    $self->render( 'riding' );
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
