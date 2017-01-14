package CoGe::Builder::Common::DataRetrieval;

use Moose;
extends 'CoGe::Builder::Buildable';

use Data::Dumper qw(Dumper);
use File::Basename qw(basename dirname);
use File::Spec::Functions qw(catfile catdir);
use String::ShellQuote qw(shell_quote);

use CoGe::Accessory::Utils qw(get_unique_id);
use CoGe::Accessory::Web qw(split_url);
use CoGe::Accessory::IRODS qw(irods_iget irods_set_env);
use CoGe::Core::Storage qw(get_upload_path get_sra_cache_path);
use CoGe::Exception::MissingField;

# Outputs
has data_files => (is => 'ro', isa => 'ArrayRef', default => sub { [] }); # input files
has data_dir   => (is => 'ro', isa => 'Str'); # input directory
has ncbi_accns => (is => 'ro', isa => 'ArrayRef', default => sub { [] }); # GenBank accessions

my $MAX_DATA_ITEMS = 100;

sub build {
    my $self = shift;
    my $data = shift;

    # Validate inputs
    unless ($data && @$data) {
        CoGe::Exception::Generic->throw(message => 'Empty source_data');
    }
    if (@$data > $MAX_DATA_ITEMS) {
        CoGe::Exception::Generic->throw(message => "Too many data items given (" . scalar(@$data) . " > $MAX_DATA_ITEMS)");
    }

    my $load_id = $self->params->{load_id} || get_unique_id();
    
    # Create tasks to retrieve files
    my $upload_dir = get_upload_path($self->user->name, $load_id);
    foreach my $item (@$data) {
        my $type = lc($item->{type});

        # Check if NCBI accession input
        if ($type eq 'ncbi') {
            #TODO move file retrieval from genbank_genome_loader.pl to here
            push @{$self->ncbi_accn}, $item->{path};
            next;
        }
        
        # Retrieve file based on source type (Upload, IRODS, HTTP, FTP)
        if ($type eq 'file') {  # upload
            my $filepath = catfile($upload_dir, $item->{path});
            if (-r $filepath) {
                $self->add_output($filepath);
            }
        }
        elsif ($type eq 'irods') {
            my $irods_path = $item->{path};
            $irods_path =~ s/^irods//; # strip of leading "irods" from LoadExperiment page # FIXME remove this in FileSelect
            $self->add_task(
                $self->iget(
                    irods_path => $irods_path, 
                    local_path => $upload_dir
                )                
            );
        }
        elsif ($type eq 'http' or $type eq 'ftp') {
            $self->add_task(
                $self->ftp_get(
                    url => $item->{url} || $item->{path},
                    username => $item->{username},
                    pasword => $item->{password},
                    dest_path => $upload_dir
                )
            );
        }
        elsif ($type eq 'sra') {
            $self->add_task(
                $self->fastq_dump(
                    accn => $item->{path},
                    dest_path => get_sra_cache_path()
                )
            );
            next;
        }

        # Process input files
        my $input_file = $self->previous_output();
        if ( $input_file =~ /\.tgz|\.tar\.gz$/ ) { # Untar if necessary
            my $output_dir = catdir($self->staging_dir, 'untarred');
            $self->add_task_chain(
                $self->untar(
                    input_file => $input_file,
                    output_path => $output_dir
                )
            );
            $self->data_dir($output_dir);
        }
        elsif ( $input_file =~ /\.gz$/ ) { # Decompress if necessary
            $self->add_task_chain(
                $self->gunzip( input_file => $input_file )
            );
            push @{$self->data_files}, $self->previous_output;
        }
        else {
            push @{$self->data_files}, $self->previous_output;
        }
    }
    
    return 1;
}

sub iget {
    my ($self, %params) = @_;
    my $irods_path = $params{irods_path}; # source path
    my $local_path = $params{local_path}; # destination path

    my $dest_file = catdir($local_path, 'irods', $irods_path);
    my $done_file = $dest_file . '.done';
    my $dest_path = dirname($dest_file);
    #make_path($dest_path) unless (-r $dest_path); # mdb removed 2/9/16 -- for hypnotoad
    
    my $cmd;
    $cmd .= "mkdir -p $dest_path && "; # mdb added 2/9/16 -- for hypnotoad
    my $irodsEnvFile = catfile($self->conf->{_HOME_PATH}, 'irodsEnv');
    irods_set_env($irodsEnvFile); # mdb added 2/9/16 -- for hypnotoad, use www-data's irodsEnvFile
    $cmd .= irods_iget( $irods_path, $dest_path, { no_execute => 1 } ) . ' && ';
    $cmd .= "touch $done_file";

    return {
        cmd => $cmd,
        args => [],
        inputs => [
            $irodsEnvFile # mdb added 11/10/16 -- attempt to fix stuck tasks, COGE-729
        ],
        outputs => [ 
            $dest_file,
            $done_file
        ],
        description => "Fetching $irods_path"
    };
}

sub ftp_get {
    my ($self, %params) = @_;
    my $url = $params{url};
    my $username = $params{username} // '';
    my $password = $params{password} // '';
    my $dest_path = $params{dest_path};
    
    my ($filename, $path) = split_url($url);
    my $output_file = catfile($dest_path, $path, $filename);

    my $cmd = catfile($self->conf->{SCRIPTDIR}, "ftp.pl");

    return {
        cmd => $cmd,
        args => [
            ['-url',       shell_quote($url),      0],
            ['-username',  shell_quote($username), 0],
            ["-password",  shell_quote($password), 0],
            ["-dest_path", $dest_path,             0]
        ],
        inputs => [
            $cmd # mdb added 11/10/16 -- attempt to fix stuck tasks, COGE-729
        ],
        outputs => [ 
            $output_file
        ],
        description => "Fetching $url"
    };
}

sub fastq_dump {
    my ($self, %params) = @_;
    my $accn = $params{accn};
    my $dest_path = $params{dest_path};
    my $read_type = $self->params->{read_params}{read_type} // 'single';

    my $cmd = $self->conf->{FASTQ_DUMP} || 'fastq-dump';
    $cmd .= ' --split-files' if ($read_type eq 'paired');

    my $output_filepath = catfile($dest_path, $accn);

    my (@output_files, @done_files);
    if ($read_type eq 'paired') {
        @output_files = (
            $output_filepath . '_1.fastq',
            $output_filepath . '_2.fastq'
        );
        @done_files = (
            $output_filepath . '_1.fastq.done',
            $output_filepath . '_2.fastq.done'
        );
    }
    else {
        @output_files = ( $output_filepath . '.fastq');
        @done_files   = ( $output_filepath . '.fastq.done' );
    }

    return {
        cmd => "mkdir -p $dest_path && $cmd --outdir $dest_path " . shell_quote($accn) . " && touch " . join(' ', @done_files),
        script => undef,
        args => [],
        inputs => [],
        outputs => [
            @output_files,
            @done_files
        ],
        description => "Fetching $accn from NCBI-SRA"
    };
}

1;