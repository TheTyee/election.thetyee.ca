#!/usr/bin/env perl
use Mojolicious::Lite;
use Mojo::UserAgent;
use Mojo::JSON;
use Modern::Perl '2013';
use Net::Google::DataAPI::Auth::OAuth2;
use Storable;
use Net::Google::Spreadsheets;
use utf8::all;
use CHI;
use Getopt::Long::Descriptive;
use Text::CSV::Slurp;
use IO::All;
use Text::StripAccents;
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

my $config = plugin 'JSONConfig' => { file => '../election_app.preview.json' };

# UserAgent
my $ua = Mojo::UserAgent->new;

my $cache = CHI->new(
    driver     => 'FastMmap',
    root_dir   => $config->{'cache_name'},
    cache_size => '50m',
    page_size  => '5026k',
);

use constant REPRESENT_API => 'http://represent.opennorth.ca';
use constant TYEE_API      => 'http://api.thetyee.ca/v1/';
use constant EBC_DATA_URI =>
   'http://static.thetyee.ca/election/v2.0.1/ui/test/GE-2017-05-09_Candidate.csv';

  #  'http://electionsbcenr.blob.core.windows.net/electionsbcenr/GE-2013-05-14_Candidate.csv';

my $oauth2 = Net::Google::DataAPI::Auth::OAuth2->new(
    client_id => $config->{'google_0auth_client'},
    client_secret => $config->{'google_0auth_secret'},
    scope => ['http://spreadsheets.google.com/feeds/'],
    redirect_uri => 'https://thetyee.ca/oauth2callback',
  );

sub gettoken() {
my $url = $oauth2->authorize_url();
# you will need to put code here and receive token
print "OAuth URL, get code: $url\n";
use Term::Prompt;
my $code = prompt('x', 'paste the code: ', '', ''); 



my $token = $oauth2->get_access_token($code) or die;






# save token for future use
 my $session = $token->session_freeze;
 store($session, 'google_spreadsheet.session');
}

# gettoken();
# RESTORE:
my $session = retrieve('google_spreadsheet.session');
my $restored_token = Net::OAuth2::AccessToken->session_thaw($session,
    auto_refresh => 1,
    profile => $oauth2->oauth2_webserver,
);
$oauth2->access_token($restored_token);

my $service = Net::Google::Spreadsheets->new(auth => $oauth2);


# Connect to Google Spreadsheets on app startup
#my $service = Net::Google::Spreadsheets->new(
#    username => $config->{'google_username'},
#    password => $config->{'google_password'},
# );

# Find the spreadsheet by key
#my $spreadsheet   = $service->spreadsheet( { key => $config->{'spreadsheet_key'}, } );

#my $spreadsheet = $service->spreadsheet(
 #   {
 #       key => '19GG-BjrZKeNTe3toRYnrtxpg_cY0VupcNtu4ryOS35k'
 #   }
 # );

my $spreadsheet = $service->spreadsheet( { title => '2017BC2013-Electoral-Ridings-Master-22-Jan-2012' } );

# app->log->debug("spreadsheet: " . Dumper($spreadsheet));


my %spreadsheets = $service->spreadsheets();


my $list;

foreach my $item (keys %spreadsheets){
  $list .= "$item: ";
  foreach my $iteminitem (keys %{$spreadsheets{$item}}){
    $list .= "$iteminitem : $spreadsheets{$item}{$iteminitem} ";
        
    
  }
 $list .= "\n";
}


# app->log->debug(Dumper($list));


# app->log->debug(Dumper($spreadsheet));

main();

sub main {
    given ( $opt->frequency ) {
        when ( /test/ ) {
            _cache_write_ridings();
        }
        when ( /minutes/ ) {
            _cache_write_ebc();
            _cache_write_ebc_lookup();
        }
        when ( /hourly/ ) {

            # Hourly
            _cache_write_ebc();
            _cache_write_ebc_lookup();
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
            _cache_write_ebc();
            _cache_write_ebc_lookup();
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
            _cache_write_ebc();
            _cache_write_ebc_lookup();
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
    
    print "name: $name \n";
    my $rep_query
        = '/boundaries/british-columbia-electoral-districts/'
        . $name
        . '/representatives/';
    my $rep_data = $ua->get( REPRESENT_API . $rep_query )->res->json;
    $rep_data = $rep_data->{'objects'}[0];
    if ($rep_data) {
    if ( $rep_data->{'party_name'} eq 'New Democratic Party of BC' ) {
        $rep_data->{'party_name'} = 'BC New Democratic Party';
    }
    $cache->set( $name . '-incumbent', $rep_data, "never" );
    } else {
         $cache->set( $name . '-incumbent',  "never" );
          use Data::Dumper;
    
       print "cache name incumbent is  " . Dumper( $cache->get( $name . '-incumbent' ));
       print "cache name is  " . Dumper( $cache->get( $name ));

        
    }
   

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
    print Dumper( $cache->get( 'ridings' ) ) if $opt->verbose;
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
    print "$name candidates";
    print Dumper($candidates);
    print Dumper( $cache->get( $name . '-candidates' ) ) if $opt->verbose;
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
    #print Dumper( $cache->get( 'candidates' ) ) if $opt->verbose;
}

sub _cache_write_poll {
    my $tx = $ua->get( $config->{'remote_inc_path'} . '/Polls/include.php' );
    if ( my $res = $tx->success ) {
        my $poll_html = $tx->res->body;
        $cache->set( 'poll', $poll_html, "never" );
    }
}

sub _cache_write_ebc {
    my $csv_data = $ua->get( EBC_DATA_URI )->res->body;
    print Dumper( $csv_data ) if $opt->verbose;
    $csv_data > io('ebc.csv'); 
    #my $data = Text::CSV::Slurp->load( string => $csv_data );
    my $data = Text::CSV::Slurp->load(file       => 'ebc.csv' , allow_loose_quotes  => 1 );
    my $sorted   = {};
    for my $d ( @$data ) {
        say "Working on " . $d->{'Electoral District Name'} if $opt->verbose;
        my $slug = lc( $d->{'Electoral District Name'} );
        $slug =~ s/\W/-/g;
        my $candidate_slug = lc( $d->{'Candidate\'s Ballot Name'} );
        $candidate_slug =~ s/\W/-/g;
        my $candidate = {
            slug    => $candidate_slug,
            name    => $d->{'Candidate\'s Ballot Name'},
            party   => $d->{'Affiliation'},
            votes   => $d->{'Total Valid Votes'},
            popular => $d->{'% of Popular Vote'},
        };
        push @{ $sorted->{ $slug }{'candidates'} },
            $candidate;
        @{ $sorted->{ $slug }{'candidates'} }
            = sort { $b->{'votes'} <=> $a->{'votes'} }
            @{ $sorted->{ $slug }{'candidates'} };
        $sorted->{ $slug }{'ballots'}
            = $d->{'Ballot Boxes Reported'};
        $sorted->{ $slug }{'time'} = $d->{'Time'};
        $sorted->{ $slug }{'id'} = $d->{'Electoral District Code'};
        my ( $reported, $total ) = split(' of ', $sorted->{ $slug }{'ballots'} );
        $sorted->{ $slug }{'reported'} = $reported;
        $sorted->{ $slug }{'total'}    = $total;
    }
    for my $r ( keys $sorted ) {
        my $riding = $sorted->{ $r };
        $cache->set( $r . '-votes', $riding, "never" );
    }
    print Dumper( $cache->get( 'vancouver-mount-pleasant-votes' ) ) if $opt->verbose;
}

sub _cache_write_ebc_lookup {
    my $candidates      = $cache->get( 'candidates' );
    my $ebc_lookup = {};
    for my $can ( @$candidates ) {
        my $key = lc( $can->{'lastname'} );
        $key     =~ s/\W/-/g;
        $ebc_lookup->{ $can->{'ebccandidateslug'} } = $key;
    }
    $cache->set( 'ebclookup2', $ebc_lookup, "never" );
    print Dumper( $cache->get( 'ebclookup2' ) ) if $opt->verbose;
}
