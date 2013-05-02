#!/usr/bin/env perl
use Mojolicious::Lite;
use Mojo::UserAgent;
use Mojo::JSON;
use Modern::Perl '2013';
use Net::Google::Spreadsheets;
use utf8::all;
use CHI;
use Getopt::Long::Descriptive;
use Data::Dumper;

my ( $opt, $usage ) = describe_options(
    'fill_the_cache %o',
    [ 'frequency|f=s' => "the frequency switch" ],
    [],
    [ 'verbose|v' => "print extra stuff" ],
    [ 'help'      => "print usage message and exit" ],
);
print( $usage->text ), exit unless $opt->frequency;
print( $usage->text ), exit if $opt->help;

my $config = plugin 'JSONConfig' => { file => '../election_app.json' };

# UserAgent
my $ua = Mojo::UserAgent->new;

my $cache = CHI->new(
    driver     => 'FastMmap',
    root_dir   => $config->{'cache_name'},
    cache_size => '10m',
    page_size  => '1024k',
);

use constant REPRESENT_API => 'http://represent.opennorth.ca';
use constant TYEE_API      => 'http://api.thetyee.ca/v1/';

# Connect to Google Spreadsheets on app startup
my $service = Net::Google::Spreadsheets->new(
    username => $config->{'google_username'},
    password => $config->{'google_password'},
);

# Find the spreadsheet by key
my $spreadsheet
    = $service->spreadsheet( { key => $config->{'spreadsheet_key'}, } );

main();

sub main {
    given ( $opt->frequency ) {
        when ( /hourly/ ) {

            # Hourly
            _cache_write_hook_posts();
            _cache_write_riding_call();
            _cache_write_poll();
        }
        when ( /daily/ ) {

            # Daily
            _cache_write_ridings();
            _cache_write_parties();
            _cache_write_party_lookup();
            _cache_write_averages();
            _cache_write_candidates();
        }
        when ( /all/ ) {
            _cache_write_hook_posts();
            _cache_write_riding_call();
            _cache_write_ridings();
            _cache_write_parties();
            _cache_write_party_lookup();
            _cache_write_averages();
            _cache_write_poll();
            _cache_write_candidates();
        }
    }
}

sub _cache_write_ridings {
    my $worksheet = $spreadsheet->worksheet(
        { title => $config->{'worksheet_name'}, } );

    my @rows = $worksheet->rows;

    for my $riding ( @rows ) {
        $riding = $riding->content;
        if ( $riding->{'slug'} ) {
            $cache->set( $riding->{'slug'}, $riding, "never" );

            # Write out the representative
            _cache_write_representative( $riding->{'slug'} );

            # Write out the candidates too
            _cache_write_candidates_by_riding( $riding->{'slug'} );
        }
    }
}

sub _cache_write_averages {
    my $worksheet = $spreadsheet->worksheet(
        { title => $config->{'worksheet_name'}, } );

    my $row = $worksheet->row( { sq => 'ridingcode = "Averages"' } );
    my $avg = $row->{'content'};
    $cache->set( 'Averages', $avg, "never" );
}

sub _cache_write_representative {
    my $name = shift;
    my $rep_query
        = '/boundaries/british-columbia-electoral-districts/'
        . $name
        . '/representatives/';
    my $rep_data = $ua->get( REPRESENT_API . $rep_query )->res->json;
    $rep_data = $rep_data->{'objects'}[0];

    if ( $rep_data->{'party_name'} eq 'New Democratic Party of BC' ) {
        $rep_data->{'party_name'} = 'BC New Democratic Party';
    }
    $cache->set( $name . '-incumbent', $rep_data, "never" );
}

sub _cache_write_parties {
    my $worksheet = $spreadsheet->worksheet(
        { title => $config->{'worksheet_name_parties'}, } );

    my @rows = $worksheet->rows();

    my $parties = {};
    for my $party ( @rows ) {
        my $party = $party->content;
        $parties->{ $party->{'slug'} } = $party;
    }
    $cache->set( 'Parties', $parties, "never" );
}

sub _cache_write_party_lookup {
    my $parties      = $cache->get( 'Parties' );
    my $party_lookup = {};
    for my $party ( sort keys $parties ) {
        $party_lookup->{ $parties->{$party}{'shortname'} }
            = $parties->{$party}->{'slug'};
    }
    $cache->set( 'PartyLookup', $party_lookup, "never" );
}

sub _cache_write_hook_posts {
    my $hook_json  = $ua->get( TYEE_API . '/latest/blogs/' )->res->json;
    my $hook_posts = $hook_json->{'hits'}{'hits'};
    $cache->set( 'HookPostsNew', $hook_posts, "never" );
}

sub _cache_write_riding_call {
    my $worksheet = $spreadsheet->worksheet(
        { title => $config->{'worksheet_name_ridings'}, } );
    my @rows    = $worksheet->rows;
    my $ridings = [];
    for my $riding ( @rows ) {
        $riding = $riding->content;
        next unless $riding->{'slug'};
        push @$ridings, $riding;
        $cache->set( $riding->{'slug'} . '-calls', $riding, "never" );
    }
    @$ridings = sort { $a->{'key'} cmp $b->{'key'} } @$ridings;
    $cache->set( 'ridings', $ridings, "never" );
}

sub _cache_write_candidates_by_riding {
    my ( $name ) = @_;
    my $worksheet = $spreadsheet->worksheet(
        { title => $config->{'worksheet_name_candidates'}, } );
    my @rows = $worksheet->rows( { sq => 'slug = "' . $name . '"' } );
    my $candidates = {};
    for my $candidate ( @rows ) {
        my $slug = lc( $candidate->content->{'lastname'} );
        $candidate->content->{'twitter'} =~ s/@//g;
        $slug =~ s/\W/-/g;
        $candidates->{$slug} = $candidate->content;
    }
    $cache->set( $name . '-candidates', $candidates, "never" );
}

sub _cache_write_candidates {
    my $worksheet = $spreadsheet->worksheet(
        { title => $config->{'worksheet_name_candidates'}, } );
    my @rows       = $worksheet->rows;
    my $candidates = [];
    for my $candidate ( @rows ) {
        $candidate->content->{'twitter'} =~ s/@//g;
        push @$candidates, $candidate->content;
    }
    @$candidates = sort { $a->{'riding'} cmp $b->{'riding'} } @$candidates;
    $cache->set( 'candidates', $candidates, "never" );
}

sub _cache_write_poll {
    my $tx = $ua->get( $config->{'remote_inc_path'} . '/Polls/include.php' );

    if ( my $res = $tx->success ) {
        my $poll_html = $tx->res->body;
        $cache->set( 'poll', $poll_html, "never" );
    }
}