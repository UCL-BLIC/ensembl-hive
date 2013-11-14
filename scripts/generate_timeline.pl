#!/usr/bin/env perl

# Gets the activity of each analysis along time, in a CSV file or in an image (see list of formats supported by GNUplot)

use strict;
use warnings;

    # Finding out own path in order to reference own components (including own modules):
use Cwd            ();
use File::Basename ();
BEGIN {
    $ENV{'EHIVE_ROOT_DIR'} = File::Basename::dirname( File::Basename::dirname( Cwd::realpath($0) ) );
    unshift @INC, $ENV{'EHIVE_ROOT_DIR'}.'/modules';
}


use Getopt::Long;
use List::Util qw(sum);
use POSIX;
use Data::Dumper;

use Bio::EnsEMBL::Hive::DBSQL::DBAdaptor;
use Bio::EnsEMBL::Hive::Utils ('script_usage');

no warnings qw{qw};

main();
exit(0);

sub main {

    my ($url, $reg_conf, $reg_type, $reg_alias, $nosqlvc, $help, $start_date, $end_date, $granularity, $skip, $output, $top);

    GetOptions(
                # connect to the database:
            'url=s'                      => \$url,
            'reg_conf|regfile=s'         => \$reg_conf,
            'reg_type=s'                 => \$reg_type,
            'reg_alias|regname=s'        => \$reg_alias,
            'nosqlvc=i'                  => \$nosqlvc,      # using "=i" instead of "!" for consistency with scripts where it is a propagated option

            'start_date=s'               => \$start_date,
            'end_date=s'                 => \$end_date,
            'granularity=i'              => \$granularity,
            'skip_no_activity=i'         => \$skip,
            'top=f'                      => \$top,
            'output=s'                   => \$output,
            'h|help'                     => \$help,
    );

    if ($help) { script_usage(0); }

    my $hive_dba;
    if($url or $reg_alias) {
        $hive_dba = Bio::EnsEMBL::Hive::DBSQL::DBAdaptor->new(
                -url                            => $url,
                -reg_conf                       => $reg_conf,
                -reg_type                       => $reg_type,
                -reg_alias                      => $reg_alias,
                -no_sql_schema_version_check    => $nosqlvc,
        );
    } else {
        warn "\nERROR: Connection parameters (url or reg_conf+reg_alias) need to be specified\n";
        script_usage(1);
    }

    # Palette generated with R: c(brewer.pal(9, "Set1"), brewer.pal(12, "Set3")). #FFFFB3 is removed because it is too close to white
    my @palette = qw(#E41A1C #377EB8 #4DAF4A #984EA3 #FF7F00 #FFFF33 #A65628 #F781BF #999999     #8DD3C7 #BEBADA #FB8072 #80B1D3 #FDB462 #B3DE69 #FCCDE5 #D9D9D9 #BC80BD #CCEBC5 #FFED6F);

    # Default options
    $granularity = 5 unless $granularity;
    $skip = int(($skip || 2*60) / $granularity);
    $top = scalar(@palette)-1 unless $top;

    my %terminal_mapping = (
        'emf' => 'emf',
        'png' => 'png',
        'svg' => 'svg',
        'jpg' => 'jpeg',
        'gif' => 'gif',
        'ps'  => 'postscript eps enhanced color',
        'pdf' => 'pdf color enhanced',
    );
    my $gnuplot_terminal = undef;
    if ($output and $output =~ /\.(\w+)$/) {
        $gnuplot_terminal = $1;
        die "The format '$gnuplot_terminal' is not currently supported." if not exists $terminal_mapping{$gnuplot_terminal};
        require Chart::Gnuplot;

    }

    my $activity_title = 'ACTIVITY';

    my $dbh = $hive_dba->dbc->db_handle();

    my @tmp_dates = @{$dbh->selectall_arrayref('SELECT DATE_FORMAT(born, "%Y-%m-%dT%T"), analysis_id, 1 FROM worker WHERE analysis_id IS NOT NULL')};
    push @tmp_dates, @{$dbh->selectall_arrayref('SELECT DATE_FORMAT(died, "%Y-%m-%dT%T"), analysis_id, -1 FROM worker WHERE analysis_id IS NOT NULL')};
    my @birth_death_dates = sort {$a->[0] cmp $b->[0]} @tmp_dates;

    warn scalar(@birth_death_dates), " events\n";
    #die Dumper $birth_death_dates[0];

    my $sql_analysis_names = 'SELECT analysis_id, logic_name FROM analysis_base';
    my $data = $dbh->selectall_arrayref($sql_analysis_names);
    my %name = (map {$_->[0] => $_->[1] } @$data);

    #die Dumper \%name;

    my $max_workers = 0;
    my @data_timings = ();
    my %tot_analysis = ();

    my $sum_a = 0;
    my %tmp_interval;
    my @activity;
    while (scalar(@birth_death_dates)) {

        my ($event_date, $analysis_id, $offset) = @{shift @birth_death_dates};
        last if $event_date gt $end_date;

        $tmp_interval{$analysis_id} += $offset;
        $sum_a += $offset;
        my %hash_interval = %tmp_interval;
        map {$tot_analysis{$_} += $hash_interval{$_}} keys %hash_interval;

        $max_workers = $sum_a if ($sum_a > $max_workers);
        next if $event_date lt $start_date;

        # We can store the data
        push @data_timings, [$event_date, \%hash_interval];
        unless ($sum_a) {
            push @activity, [$event_date, 1];
            push @activity, [$event_date, 0];
            push @activity, [$birth_death_dates[0]->[0], 0] if scalar(@birth_death_dates);
            push @activity, [$birth_death_dates[0]->[0], 1] if scalar(@birth_death_dates);
        }
    }
    warn $max_workers;
    warn Dumper \%tot_analysis;

    my $total_total = sum(values %tot_analysis);

    my @sorted_analysis_ids = sort {($tot_analysis{$b} <=> $tot_analysis{$a}) || (lc $name{$a} cmp lc $name{$b})} keys %tot_analysis;
    warn Dumper \@sorted_analysis_ids;
    warn Dumper([map {$name{$_}} @sorted_analysis_ids]);

    if (not $gnuplot_terminal) {
        print join("\t", 'analysis', $activity_title, map {$name{$_}} @sorted_analysis_ids), "\n";
        print join("\t", 'total', $total_total, map {$tot_analysis{$_}} @sorted_analysis_ids), "\n";
        print join("\t", 'proportion', '0', map {$tot_analysis{$_}/$total_total} @sorted_analysis_ids), "\n";
        my $s = 0;
        print join("\t", 'cum_proportion', '0', map {$s+=$tot_analysis{$_}/$total_total} @sorted_analysis_ids), "\n";

        my @buffer = ();
        foreach my $row (@data_timings) {
            my $str = join("\t", $row->[0], sum(values %{$row->[1]}), map {$row->[1]->{$_} || 0} @sorted_analysis_ids)."\n";
            if ($row->[1]) {
                if (@buffer) {
                    my $n = scalar(@buffer);
                    if ($n > $skip) {
                        splice(@buffer, int($skip / 2), $n-$skip);
                    }
                    foreach my $old_str (@buffer) {
                        print $old_str;
                    }
                    @buffer = ();
                }
                print $str;
            } else {
                push @buffer, $str;
            }
        }
        return;
    }

    # Get the number of analysis we want to display
    my $n_relevant_analysis = 0;
    if ($top and $top > 0) {
        if ($top < 1) {
            my $s = 0;
            map {my $pre_s = $s; $s += $tot_analysis{$_}/$total_total; $pre_s < .995 && $n_relevant_analysis++} @sorted_analysis_ids;
        } else {
            $n_relevant_analysis = $top
        }
    } else {
        $n_relevant_analysis = scalar(@sorted_analysis_ids);
    }

    warn $n_relevant_analysis;

    my @xdata = map {$_->[0]} @data_timings;

    my @datasets = ();

    {
        push @datasets, Chart::Gnuplot::DataSet->new(
            xdata => [map {$_->[0]} @activity],
            ydata => [map {$max_workers*(1-0.03*$_->[1])} @activity],
            timefmt => '%Y-%m-%dT%H:%M:%S',
            title => $activity_title,
            style => sprintf('filledcurves below y1=%d', int($max_workers)),
            linetype => '2',
            linewidth => '0',
            color => '#2F4F4F',
        );
    }
    {
        my @ydata = ();
        foreach my $row (@data_timings) {
            push @ydata, sum(map {$row->[1]->{$_} || 0} @sorted_analysis_ids );
        }
        push @datasets, Chart::Gnuplot::DataSet->new(
            xdata => \@xdata,
            ydata => \@ydata,
            timefmt => '%Y-%m-%dT%H:%M:%S',
            title => 'OTHER',
            style => 'filledcurves',
            linewidth => '0',
            color => $palette[$n_relevant_analysis],
        );
    }

    foreach my $i (reverse 1..$n_relevant_analysis) {
        my @ydata;
        foreach my $row (@data_timings) {
            push @ydata, sum(map {$row->[1]->{$_} || 0} @sorted_analysis_ids[0..($i-1)] );
        }
        my $dataset = Chart::Gnuplot::DataSet->new(
            xdata => \@xdata,
            ydata => \@ydata,
            timefmt => '%Y-%m-%dT%H:%M:%S',
            title => $name{$sorted_analysis_ids[$i-1]},
            style => 'filledcurves',
            linewidth => '0',
            color => $palette[$i-1],
        );
        push @datasets, $dataset;
    }

    my $chart = Chart::Gnuplot->new(
        title => sprintf('Profile of %s', $n_relevant_analysis < scalar(@sorted_analysis_ids) ? ($top < 1 ? sprintf('%.1f%% of %s', 100*$top, $url) : "the $top top-analysis of $url") : $url).($start_date ? " from $start_date" : "").($end_date ? " until $end_date" : ""),
        timeaxis => 'x',
        legend => {
            position => 'outside right',
            align => 'left',
        },
        xtics => {
            labelfmt => '%b %d',
        },
        bg => {
            color => 'white',
        },
        imagesize => '1400, 800',
        output => $output,
        terminal => $terminal_mapping{$gnuplot_terminal},
        ylabel => 'Number of workers',
    );
    $chart->plot2d(@datasets);

}



__DATA__

=pod

=head1 NAME

    generate_profile.pl

=head1 DESCRIPTION

    This script is used for offline examination of the allocation of workers.

    Based on the command-line parameters 'start_date' and 'end_date', or on the start time of the first
    worker and end time of the last worker (as recorded in pipeline DB), it pulls the relevant data out
    of the 'worker' table for accurate timing.
    By default, the output is in CSV format, to allow extra analaysis to be carried.

    You can optionally ask the script to generate an image with Gnuplot.

    Please note the script runs a query for each interval (default: 5 minutes), which can take some time
    for long-running pipelines.

=head1 USAGE EXAMPLES

        # Just run it the usual way: only the top 19 analysis will be reported in CSV format
    generate_profile.pl -url mysql://username:secret@hostname:port/database > profile.csv

        # The same, but getting the analysis that fill 99.5% of the global activity in a PNG file
    generate_profile.pl -url mysql://username:secret@hostname:port/database -top .995 -output profile.png

        # Assuming you are only interested in a precise interval (in a PNG file)
    generate_profile.pl -url mysql://username:secret@hostname:port/database -start_date 2013-06-15T10:34 -end_date 2013-06-15T16:58 -granularity 1 -output profile.png

        # Assuming that the pipeline has large periods of inactivity
    generate_profile.pl -url mysql://username:secret@hostname:port/database -granularity 10 -skip_no_activity 1 > profile.csv

=head1 OPTIONS

    -help                   : print this help
    -url <url string>       : url defining where hive database is located
    -start_date <date>      : minimal start date of a worker (the format is ISO8601, e.g. '2012-01-25T13:46')
    -end_date <date>        : maximal end date of a worker (the format is ISO8601, e.g. '2012-01-25T13:46')
    -granularity <int>      : size of the intervals on which the activity is computed (minutes) (default: 5)
    -skip_no_activity <int> : only for CSV output: shrink the periods of inactivity which are longer than "skip_no_activity" hours (default: 2)
    -top <float>            : maximum number (> 1) or fraction (< 1) of analysis to report (default: 19)
    -output <string>        : output file: its extension must match one of the Gnuplot terminals. Otherwise, the CSV output is produced on stdout

=head1 CONTACT

    Please contact ehive-users@ebi.ac.uk mailing list with questions/suggestions.

=cut
