#!/usr/bin/env perl
use Modern::Perl '2013';
use Mojo::UserAgent;
use JSON;
use IO::All;
use utf8::all;
use Getopt::Long::Descriptive;
use Data::Dumper;

my ($opt, $usage) = describe_options(
  'get_boundaries_output_geojson %o',
  [ 'filename|f=s' => "the name of the file to output"                  ],
  [],
  [ 'verbose|v' =>  "print extra stuff"            ],
  [ 'help'      =>  "print usage message and exit" ],
);
print($usage->text), exit unless $opt->filename;
print($usage->text), exit if $opt->help;

use constant API_URL => 'http://represent.opennorth.ca';

my $ua = Mojo::UserAgent->new;
my $json = $ua->get( API_URL . '/boundaries/british-columbia-electoral-districts/?offset=0&limit=100')->res->json;

my $ridings = $json->{'objects'};
my $json_obj = { 
    type => "FeatureCollection",
    features => [],
};

for my $riding ( @$ridings ) {
    say "Working on " . $riding->{'name'} . ': ' . $riding->{'external_id'} if $opt->verbose;
    my $riding_obj = $ua->get( API_URL . $riding->{'url'} )->res->json;
    my $geom = $ua->get( API_URL . $riding_obj->{'related'}->{'simple_shape_url'} )->res->json;
    while ( $geom eq '' || $geom eq 'null' ) {
        say "Got a null on " . $riding->{'name'} . " ... sleeping" if $opt->verbose;
        sleep 3;
        $geom = $ua->get( API_URL . $riding_obj->{'related'}->{'simple_shape_url'} )->res->json;
    }
    my $feature = { 
        type => "Feature",
        id => $riding_obj->{'external_id'},
        properties => $riding_obj, 
        geometry    => $geom,
    };
    push $json_obj->{'features'}, $feature;
    say Dumper( $feature->{'properties'}  ) if $opt->verbose;
    sleep 3;
}

my $js = JSON->new->allow_nonref;
my $json_str = $js->encode( $json_obj );

$json_str > io( $opt->filename ); # Print to a file
