package CoGe::Builder::Protein::ChIPseq;

use v5.14;
use strict;
use warnings;

use Data::Dumper qw(Dumper);
use Clone qw(clone);
use File::Basename;
use File::Spec::Functions qw(catdir catfile);
use CoGe::Accessory::Utils qw(to_filename to_filename_without_extension to_filename_base);
use CoGe::Accessory::Web qw(get_defaults);
use CoGe::Core::Storage qw(get_workflow_paths get_genome_cache_path);
use CoGe::Core::Metadata qw(to_annotations);
use CoGe::Builder::CommonTasks;

our $CONF = CoGe::Accessory::Web::get_defaults();

BEGIN {
    use vars qw ($VERSION @ISA @EXPORT @EXPORT_OK);
    require Exporter;

    $VERSION = 0.1;
    @ISA     = qw(Exporter);
    @EXPORT  = qw(build);
}

sub build {
    my $opts = shift;
    my $genome = $opts->{genome};
    my $user = $opts->{user};
    my $input_files = $opts->{input_files}; # path to input bam files
    my $metadata = $opts->{metadata};
    my $additional_metadata = $opts->{additional_metadata};
    my $wid = $opts->{wid};
    my $chipseq_params = $opts->{chipseq_params};
    die unless ($genome && $user && $input_files && @$input_files && $wid);
    
    # Require 3 data files (input and two replicates)
    if (@$input_files != 3) {
        print STDERR "CoGe::Builder::Protein::ChIPseq ERROR: 3 input files required\n", Dumper $input_files, "\n";
        return;
    }

    # Setup paths
    my ($staging_dir) = get_workflow_paths($user->name, $wid);

    # Set metadata for the pipeline being used
    my $annotations = generate_additional_metadata($chipseq_params);
    my @annotations2 = CoGe::Core::Metadata::to_annotations($additional_metadata);
    push @$annotations, @annotations2;

    # Determine which bam file corresponds to the input vs. the replicates
    die unless ($chipseq_params->{input});
    my $input_base = to_filename_base($chipseq_params->{input});
    my ($input_file, @replicates);
    foreach my $file (@$input_files) {
        my ($basename) = to_filename_base($file);
        if (index($basename, $input_base) != -1) {
            $input_file = $file;
        }
        else {
            push @replicates, $file;
        }
    }
    die "CoGe::Builder::Protein::ChIPseq: ERROR, unable to detect input, base=$input_base, files: ", Dumper @$input_files unless $input_file;

    #
    # Build the workflow
    #
    my (@tasks, @done_files);

    foreach my $bam_file (@$input_files) {
        my $bamToBed_task = create_bamToBed_job(
            bam_file => $bam_file,
            staging_dir => $staging_dir
        );
        push @tasks, $bamToBed_task;
        
        my $makeTagDir_task = create_homer_makeTagDirectory_job(
            bed_file => $bamToBed_task->{outputs}[0],
            gid => $genome->id,
            staging_dir => $staging_dir,
            params => $chipseq_params
        );
        push @tasks, $makeTagDir_task;
    }
    
    foreach my $replicate (@replicates) {
        my ($input_tag) = to_filename_base($input_file);
        my ($replicate_tag) = to_filename_base($replicate);
        
        my $findPeaks_task = create_homer_findPeaks_job(
            input_dir => catdir($staging_dir, $input_tag),
            replicate_dir => catdir($staging_dir, $replicate_tag),
            staging_dir => $staging_dir,
            params => $chipseq_params
        );
        push @tasks, $findPeaks_task;
        
        my $convert_task = create_convert_homer_to_csv_job(
            input_file => $findPeaks_task->{outputs}[0],
            staging_dir => $staging_dir
        );
        push @tasks, $convert_task;
        
        my $md = clone($metadata);
        $md->{name} .= " ($input_tag vs. $replicate_tag) (ChIP-seq)";
        push @{$md->{tags}}, 'ChIP-seq';
        
        my $load_task = create_load_experiment_job(
            user => $user,
            metadata => $md,
            staging_dir => $staging_dir,
            wid => $wid,
            gid => $genome->id,
            input_file => $convert_task->{outputs}[0],
            name => $replicate_tag,
            normalize => 'percentage',
            annotations => $annotations
        );
        push @tasks, $load_task;
        push @done_files, $load_task->{outputs}[1];
    }

    return {
        tasks => \@tasks,
        done_files => \@done_files
    };
}

sub generate_additional_metadata {
    my $chipseq_params = shift;
    $chipseq_params->{'-fragLength'} = $chipseq_params->{'-size'}; # kludge b/c "size" is used for "fragLength" argument
    
    my @annotations;
    push @annotations, qq{https://genomevolution.org/wiki/index.php?title=LoadExperiment||note|Generated by CoGe's NGS Analysis Pipeline};
    push @annotations, 'note|makeTagDirectory ' . join(' ', map { $_.' '.$chipseq_params->{$_} } ('-fragLength', '-checkGC'));
    push @annotations, 'note|findPeaks ' . join(' ', map { $_.' '.$chipseq_params->{$_} } ('-size', '-gsize', '-norm', '-fdr', '-F'));
    
    return \@annotations;
}

sub create_bamToBed_job {
    my %opts = @_;
    my $bam_file    = $opts{bam_file};
    my $staging_dir = $opts{staging_dir};
    die unless ($bam_file && $staging_dir);
    
    my $cmd = $CONF->{BAMTOBED} || 'bamToBed';
    
    my $name = to_filename_base($bam_file);
    my $bed_file = catfile($staging_dir, $name . '.bed');
    my $done_file = $bed_file . '.done';
    
    return {
        cmd => "$cmd -i $bam_file > $bed_file ; touch $done_file",
        script => undef,
        args => [],
        inputs => [
            $bam_file
        ],
        outputs => [
            $bed_file,
            $done_file
        ],
        description => "Converting $name BAM file to BED format"
    };
}

sub create_homer_makeTagDirectory_job {
    my %opts = @_;
    my $bed_file    = $opts{bed_file};
    my $gid         = $opts{gid};
    my $staging_dir = $opts{staging_dir};
    my $params = $opts{params} // {};
    my $size   = $params->{'-size'} // 250;
    die unless ($bed_file && $gid && $staging_dir);
    
    die "ERROR: HOMER_DIR is not in the config." unless $CONF->{HOMER_DIR};
    my $cmd = catfile($CONF->{HOMER_DIR}, 'makeTagDirectory');
    
    my $tag_name = to_filename_base($bed_file);
    
    my $fasta = catfile(get_genome_cache_path($gid), 'genome.faa.reheader.faa'); #TODO move into function in Storage.pm
    
    return {
        cmd => $cmd,
        script => undef,
        args => [
            ['', $tag_name, 0],
            ['', $bed_file, 0],
            ['-fragLength', $size, 0],
            ['-format', 'bed', 0],
            ['-genome', $fasta, 0],
            ['-checkGC', '', 0]
        ],
        inputs => [
            $bed_file,
            $bed_file . '.done',
            $fasta
        ],
        outputs => [
            [catfile($staging_dir, $tag_name), 1],
            catfile($staging_dir, $tag_name, 'tagInfo.txt')
        ],
        description => "Creating tag directory '$tag_name' using Homer"
    };
}

sub create_homer_findPeaks_job {
    my %opts = @_;
    my $replicate_dir = $opts{replicate_dir};
    my $input_dir     = $opts{input_dir};
    my $staging_dir   = $opts{staging_dir};
    my $params = $opts{params} // {};
    my $size   = $params->{'-size'} // 250;
    my $gsize  = $params->{'-gsize'} // 3000000000;
    my $norm   = $params->{'-norm'} // 1e8;
    my $fdr    = $params->{'-fdr'} // 0.01;
    my $F      = $params->{'-F'} // 3;
    die unless ($replicate_dir && $input_dir && $staging_dir);
    
    die "ERROR: HOMER_DIR is not in the config." unless $CONF->{HOMER_DIR};
    my $cmd = catfile($CONF->{HOMER_DIR}, 'findPeaks');
    
    my ($replicate_tag) = to_filename_base($replicate_dir);
    
    my $output_file = "homer_peaks_$replicate_tag.txt";
    
    return {
        cmd => $cmd,
        script => undef,
        args => [
            ['', $replicate_dir, 0],
            ['-i', $input_dir, 0],
            ['-style', 'factor', 0],
            ['-o', $output_file, 0],
            ['-size', $size, 0],
            ['-gsize', $gsize, 0],
            ['-norm', $norm, 0],
            ['-fdr', $fdr, 0],
            ['-F', $F, 0]
        ],
        inputs => [
            [$replicate_dir, 1],
            [$input_dir, 1]
        ],
        outputs => [
            catfile($staging_dir, $output_file)
        ],
        description => "Performing ChIP-seq analysis on $replicate_tag using Homer"
    };
}

sub create_convert_homer_to_csv_job {
    my %opts = @_;
    my $input_file = $opts{input_file};
    my $staging_dir = $opts{staging_dir};
    
    die "ERROR: SCRIPTDIR not specified in config" unless $CONF->{SCRIPTDIR};
    my $cmd = catfile($CONF->{SCRIPTDIR}, 'chipseq', 'homer_peaks_to_csv.pl');
    
    my $name = to_filename_without_extension($input_file);
    my $output_file = catfile($staging_dir, $name . '.csv');
    my $done_file = $output_file . '.done';
    
    return {
        cmd => "$cmd $input_file > $output_file ; touch $done_file",
        script => undef,
        args => [],
        inputs => [
            $input_file
        ],
        outputs => [
            $output_file,
            $done_file
        ],
        description => "Converting $name to CSV format"
    };
}

1;