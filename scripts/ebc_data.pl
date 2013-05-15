#!/usr/bin/env perl
use Mojolicious::Lite;
use Mojo::UserAgent;
use Mojo::JSON;
use Modern::Perl '2013';
use utf8::all;
use CHI;
use Getopt::Long::Descriptive;
use Text::CSV::Slurp;
use Data::Dumper;

my $config = plugin 'JSONConfig' => { file => '../election_app.json' };

# UserAgent
my $ua = Mojo::UserAgent->new;

use constant EBC_DATA_URI =>
    'https://docs.google.com/spreadsheet/pub?key=0AgZzmiG9MvT4dFJqSWpUUVNWRHpvVWI0dEpxV0VMV0E&output=csv';

my $csv_data = $ua->get( EBC_DATA_URI )->res->body;

my $data = Text::CSV::Slurp->load( string => $csv_data );

#print Dumper( $data );

my $sorted = {};

for my $d ( @$data ) {
    my $candidate_slug = lc( $d->{'Candidate\'s Ballot Name'} );
    $candidate_slug =~ s/\W/-/g;

    #say $candidate_slug;
    my $candidate = {
        slug    => $candidate_slug,
        name    => $d->{'Candidate\'s Ballot Name'},
        party   => $d->{'Affiliation'},
        votes   => $d->{'Total Valid Votes'},
        popular => $d->{'% of Popular Vote'},
    };
    push @{ $sorted->{ $d->{'Electoral District Code'} }{'candidates'} },
        $candidate;
    @{ $sorted->{ $d->{'Electoral District Code'} }{'candidates'} }
        = sort { $b->{'votes'} <=> $a->{'votes'} }
        @{ $sorted->{ $d->{'Electoral District Code'} }{'candidates'} };
    $sorted->{ $d->{'Electoral District Code'} }{'ballots'}
        = $d->{'Ballot Boxes Reported'};
    $sorted->{ $d->{'Electoral District Code'} }{'time'} = $d->{'Time'};
}

print Dumper( $sorted->{'ABM'} );
