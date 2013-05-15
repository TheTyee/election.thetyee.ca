#!/usr/bin/env perl
use Modern::Perl '2013';
use Mojolicious::Lite;
use Net::Google::Spreadsheets;
use JSON;
use IO::All;
use utf8::all;
use Getopt::Long::Descriptive;
use Text::CSV::Slurp;
use Text::StripAccents;
use Data::Dumper;

my ( $opt, $usage ) = describe_options(
    'get_boundaries_output_geojson %o',
    [ 'json|j=s'     => "the name json file to input" ],
    [ 'filename|f=s' => "the name of the file to output" ],
    [],
    [ 'verbose|v' => "print extra stuff" ],
    [ 'help'      => "print usage message and exit" ],
);
print( $usage->text ), exit unless $opt->filename;
print( $usage->text ), exit if $opt->help;

my $config
    = plugin 'JSONConfig' => { file => '../election_app.production.json' };

# Connect to Google Spreadsheets
my $service = Net::Google::Spreadsheets->new(
    username => $config->{'google_username'},
    password => $config->{'google_password'},
);

# Read the .json file into a data structure
my $json = JSON->new->allow_nonref;
my $json_str < io $opt->json;
my $data     = $json->decode( $json_str );
my $features = $data->{'features'};

my $json_obj = {
    type     => "FeatureCollection",
    features => [],
};

# Update the data structure with data from Google Spreadsheet
for my $feature ( @$features ) {
    say $feature->{'id'} if $opt->verbose;
    my $tyee_call = _get_riding_from_gs( $feature->{'id'} );
    $feature->{'properties'}{'win_copy'} = $tyee_call->{'winnercommentary'};
    $feature->{'properties'}{'results'}
        = _get_winner_from_ebc( $feature->{'id'} );
    my $winner = $feature->{'properties'}{'results'}{'winner'};
    my $candidate = _get_candidate_from_gs( @$winner[0]->{'slug'} );
    my $party     = _get_party_from_gs( $candidate->{'party'} );

    print Dumper( $winner, $candidate, $party );
    $feature->{'properties'}{'party'}     = $party;
    $feature->{'properties'}{'winner'} = $candidate;
    push $json_obj->{'features'}, $feature;
}

print Dumper( $json_obj ) if $opt->verbose;

# Output a .js file with var ridingData =
my $js_str = 'var ridingData = ' . $json->encode( $data );
$js_str > io( $opt->filename );    # Print to a file

######################################################################
# Subroutines
######################################################################
sub _get_riding_from_gs {
    my ( $id ) = @_;

    # Find the spreadsheet by key
    my $spreadsheet
        = $service->spreadsheet( { key => $config->{'spreadsheet_key'}, } );

    # Find the main worksheet by title
    my $worksheet = $spreadsheet->worksheet( { title => 'Ridings', } );

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
    my $worksheet = $spreadsheet->worksheet( { title => 'Parties', } );

    my $row = $worksheet->row( { sq => 'officialname = "' . $name . '"' } );

    #$riding = $row->{'content'};
    my $party = {};
    $party = $row->{'content'};
    return $party;
}

sub _get_candidate_from_gs {
    my ( $name ) = @_;

    # Find the spreadsheet by key
    my $spreadsheet
        = $service->spreadsheet( { key => $config->{'spreadsheet_key'}, } );

    # Find the main worksheet by title
    my $worksheet = $spreadsheet->worksheet( { title => 'Candidates', } );
    my @row = $worksheet->rows(
        { sq => 'ebccandidateslug = "' . $name . '"'  } );
    my $candidate = {};
    $candidate = $row[0]->{'content'};
    return $candidate;
}

sub _get_winner_from_ebc {
    my $name = shift;
    #my $data = Text::CSV::Slurp->load( string => $csv_data );
    my $data = Text::CSV::Slurp->load( file => 'ebc.csv',
        allow_loose_quotes => 1 );
    my $sorted = {};
    for my $d ( @$data ) {
        next unless $d->{'Electoral District Code'} eq $name;
        say "Working on " . $d->{'Electoral District Name'} if $opt->verbose;

        #my $slug = lc( $d->{'Electoral District Name'} );
        #$slug =~ s/\W/-/g;
        my $slug           = $d->{'Electoral District Code'};
        my $candidate_slug = lc( $d->{'Candidate\'s Ballot Name'} );
        $candidate_slug =~ s/\W/-/g;
        my $candidate = {
            slug    => $candidate_slug,
            name    => $d->{'Candidate\'s Ballot Name'},
            party   => $d->{'Affiliation'},
            votes   => $d->{'Total Valid Votes'},
            popular => $d->{'% of Popular Vote'},
        };
        push @{ $sorted->{$slug}{'candidates'} }, $candidate;
        @{ $sorted->{$slug}{'candidates'} }
            = sort { $b->{'votes'} <=> $a->{'votes'} }
            @{ $sorted->{$slug}{'candidates'} };
        $sorted->{$slug}{'ballots'} = $d->{'Ballot Boxes Reported'};
        $sorted->{$slug}{'time'}    = $d->{'Time'};
        my ( $reported, $total )
            = split( ' of ', $sorted->{$slug}{'ballots'} );
        $sorted->{$slug}{'reported'} = $reported;
        $sorted->{$slug}{'total'}    = $total;
        $sorted->{$slug}{'winner'}   = $sorted->{$slug}{'candidates'};
    }
    return $sorted->{ $name };
}
