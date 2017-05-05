#!/usr/bin/env perl
use Modern::Perl '2013';
use Mojolicious::Lite;
use Net::Google::Spreadsheets;
use Net::Google::DataAPI::Auth::OAuth2;
use Storable;
use JSON;
use IO::All;
use utf8::all;
use Getopt::Long::Descriptive;
use Data::Dumper;

my ($opt, $usage) = describe_options(
  'get_boundaries_output_geojson %o',
  [ 'json|j=s' => "the name json file to input"                     ],
  [ 'filename|f=s' => "the name of the file to output"                  ],
  [],
  [ 'verbose|v' =>  "print extra stuff"            ],
  [ 'help'      =>  "print usage message and exit" ],
);
print($usage->text), exit unless $opt->filename;
print($usage->text), exit if $opt->help;

my $config = plugin 'JSONConfig' => {file => '../election_app.preview.json'};

# Connect to Google Spreadsheets
#my $service = Net::Google::Spreadsheets->new(
#    username => $config->{'google_username'},
 #   password => $config->{'google_password'},
#);


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

gettoken();
# RESTORE:
my $session = retrieve('google_spreadsheet.session');
my $restored_token = Net::OAuth2::AccessToken->session_thaw($session,
    auto_refresh => 1,
    profile => $oauth2->oauth2_webserver,
);
$oauth2->access_token($restored_token);

my $service = Net::Google::Spreadsheets->new(auth => $oauth2);



# Read the .json file into a data structure
my $json = JSON->new->allow_nonref;
my $json_str < io $opt->json;
my $data = $json->decode( $json_str );
my $features = $data->{'features'};


my $json_obj = { 
    type => "FeatureCollection",
    features => [],
};

# Update the data structure with data from Google Spreadsheet
for my $feature ( @$features ) {
    say $feature->{'properties'}{'ED_ABBREVIATION'};
    my $tyee_call   = _get_riding_from_gs( $feature->{'properties'}{'ED_ABBREVIATION'} );
    $feature->{'properties'}{'call'} = $tyee_call->{'call'};
    $feature->{'properties'}{'reason'} = $tyee_call->{'reasoning'};
    if ( $tyee_call->{'party'} ) {
        my $party       = _get_party_from_gs( $tyee_call->{'party'} );
        my $candidate   = _get_candidate_from_gs( $tyee_call->{'name'}, $tyee_call->{'party'} );
        $feature->{'properties'}{'party'} = $party;
        $feature->{'properties'}{'candidate'} = $candidate;
    }
    push $json_obj->{'features'}, $feature;
};

# Output a .js file with var ridingData = 
my $js_str = 'var ridingData = ' . $json->encode( $data );
$js_str > io( $opt->filename ); # Print to a file


######################################################################
# Subroutines
######################################################################
sub _get_riding_from_gs {
    my ( $id ) = @_;

    # Find the spreadsheet by key
#    my $spreadsheet
#    = $service->spreadsheet( { key => $config->{'spreadsheet_key'}, } );
# no do it by title becaues keys lookup are broken?
my $spreadsheet = $service->spreadsheet( { title => '2017BC2013-Electoral-Ridings-Master-22-Jan-2012' } );


    # Find the main worksheet by title
    my $worksheet = $spreadsheet->worksheet(
        { title => 'Ridings', } );

    my $row = $worksheet->row( { sq => 'key = "' . $id . '"' } );
    my $riding = {};
    $riding = $row->{'content'};

    return $riding;
}
sub _get_party_from_gs {
    my ( $name ) = @_;

    # Find the spreadsheet by key
   # my $spreadsheet
   # = $service->spreadsheet( { key => $config->{'spreadsheet_key'}, } );
# no do it by title becaues key are broken?
my $spreadsheet = $service->spreadsheet( { title => '2017BC2013-Electoral-Ridings-Master-22-Jan-2012' } );

   
   
    # Find the main worksheet by title
    my $worksheet = $spreadsheet->worksheet(
        { title => 'Parties', } );

    my $row = $worksheet->row( { sq => 'officialname = "' . $name . '"' } );
    #$riding = $row->{'content'};
    my $party = {};
    $party = $row->{'content'};
    return $party;
}
sub _get_candidate_from_gs {
    my ( $name, $party ) = @_;

    # Find the spreadsheet by key
    #my $spreadsheet
    #= $service->spreadsheet( { key => $config->{'spreadsheet_key'}, } );

    # no do it by title becaues key are broken?
my $spreadsheet = $service->spreadsheet( { title => '2017BC2013-Electoral-Ridings-Master-22-Jan-2012' } );

   
    
    # Find the main worksheet by title
    my $worksheet = $spreadsheet->worksheet(
        { title => 'Candidates', } );
    my @row = $worksheet->rows( { sq => 'riding = "' . $name . '" and party = "' . $party . '"' } );
    my $candidate = {};
    $candidate = $row[0]->{'content'};
    return $candidate;
}
