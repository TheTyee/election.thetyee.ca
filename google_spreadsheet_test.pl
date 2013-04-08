#!/usr/bin/env perl
use Mojolicious::Lite;
use Mojo::UserAgent;
use Net::Google::Spreadsheets;
use Data::Dumper;

my $config = plugin 'JSONConfig'; 

# Connect to Google Spreadsheets on app startup
my $service = Net::Google::Spreadsheets->new(
    username => $config->{'google_username'},
    password => $config->{'google_password'},
);
print Dumper( $service );

# Find the spreadsheet by key
my $spreadsheet
= $service->spreadsheet( { key => $config->{'spreadsheet_key'}, } );
print Dumper( $spreadsheet );

# Find the main worksheet by title
my $worksheet = $spreadsheet->worksheet(
    { title => $config->{'worksheet_name'}, } );

print Dumper( $worksheet );
