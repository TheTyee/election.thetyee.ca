#!/usr/bin/env perl
use Modern::Perl '2013';
use Mojolicious::Lite;
use Net::Google::Spreadsheets;
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

my $config = plugin 'JSONConfig' => {file => '../election_app.production.json'};

# Connect to Google Spreadsheets
my $service = Net::Google::Spreadsheets->new(
    username => $config->{'google_username'},
    password => $config->{'google_password'},
);

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
    say $feature->{'id'};
    my $tyee_call   = _get_riding_from_gs( $feature->{'id'} );
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
    my $spreadsheet
    = $service->spreadsheet( { key => $config->{'spreadsheet_key'}, } );

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
    my $spreadsheet
    = $service->spreadsheet( { key => $config->{'spreadsheet_key'}, } );

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
    my $spreadsheet
    = $service->spreadsheet( { key => $config->{'spreadsheet_key'}, } );

    # Find the main worksheet by title
    my $worksheet = $spreadsheet->worksheet(
        { title => 'Candidates', } );
    my @row = $worksheet->rows( { sq => 'riding = "' . $name . '" and party = "' . $party . '"' } );
    my $candidate = {};
    $candidate = $row[0]->{'content'};
    return $candidate;
}
