#!/usr/bin/env perl
use Mojolicious::Lite;
use Mojo::UserAgent;
use Mojo::JSON;
use Modern::Perl '2013';
use utf8::all;
use CHI;
use Getopt::Long::Descriptive;
use Text::CSV::Slurp;
use IO::All;
use Data::Dumper;

my $config = plugin 'JSONConfig' => { file => '../election_app.json' };

# UserAgent
my $ua = Mojo::UserAgent->new;

use constant EBC_DATA_URI =>
    'http://electionsbcenr.blob.core.windows.net/electionsbcenr/GE-2013-05-14_Candidate.csv';

my $csv_data = $ua->get( EBC_DATA_URI )->res->body;

#print Dumper( $csv_data );

#$csv_data = substr $csv_data, 3;

#print Dumper( $csv_data );

$csv_data > io('ebc.csv'); 

#my $data = Text::CSV::Slurp->load( string => $csv_data );
my $data = Text::CSV::Slurp->load(file       => 'ebc.csv');


print Dumper( $data );
