package CoGe::Services::API::JBrowse::Experiment;

use Mojo::Base 'Mojolicious::Controller';
use Mojo::JSON;

use CoGeX;
use CoGe::Accessory::histogram;
use CoGe::Services::API::JBrowse::FeatureIndex;
use CoGe::Services::Auth qw( init );
use CoGe::Core::Experiment qw( get_data );
use CoGe::Core::Storage qw( get_experiment_path );
use CoGeDBI qw( feature_type_names_to_id );
use Data::Dumper;
use File::Path;
use File::Spec::Functions;
use JSON::XS;

#TODO: use these from Storage.pm instead of redeclaring them
my $DATA_TYPE_QUANT  = 1; # Quantitative data
my $DATA_TYPE_POLY	 = 2; # Polymorphism data
my $DATA_TYPE_ALIGN  = 3; # Alignments
my $DATA_TYPE_MARKER = 4; # Markers

my $NUM_QUANT_COL   = 6;
my $NUM_VCF_COL     = 9;
my $NUM_GFF_COL     = 7;
my $MAX_EXPERIMENTS = 20;
my $MAX_WINDOW_SIZE = 1000000;#500000;

my $QUAL_ENCODING_OFFSET = 33;

sub stats_global {
    my $self = shift;
	print STDERR "JBrowse::Experiment::stats_global\n";
    $self->render(json => {
		"scoreMin" => -1,
		"scoreMax" => 1
	});
}

sub stats_regionFeatureDensities { #FIXME lots of code in common with features()
    my $self     = shift;
    my $eid      = $self->stash('eid');
    my $nid      = $self->stash('nid');
    my $gid      = $self->stash('gid');
    my $chr      = $self->stash('chr');
    my $start    = $self->param('start');
    my $end      = $self->param('end');
    my $bpPerBin = $self->param('basesPerBin');

#	print STDERR "JBrowse::Experiment::stats_regionFeatureDensities eid="
#      . ( $eid ? $eid : '' ) . " nid="
#      . ( $nid ? $nid : '' ) . " gid="
#      . ( $gid ? $gid : '' )
#      . " $chr:$start:$end ("
#      . ( $end - $start + 1 )
#      . ") bpPerBin=$bpPerBin\n";

    # Authenticate user and connect to the database
    my ($db, $user) = CoGe::Services::Auth::init($self);

	my $experiments = _get_experiments($db, $user, $eid, $gid, $nid);

	# Query range for each experiment and build up json response - #TODO could parallelize this for multiple experiments
    my @bins;
    foreach my $exp (@$experiments) {
        my $data_type = $exp->data_type;
		if ( !$data_type or $data_type == $DATA_TYPE_QUANT ) {
			next;
		}
        my $pData = CoGe::Core::Experiment::get_data(
            eid   => $eid,
            data_type  => $exp->data_type,
            chr   => $chr,
            start => $start,
            end   => $end
        );
        if ( $data_type == $DATA_TYPE_POLY || $data_type == $DATA_TYPE_MARKER ) {
            # Bin and convert to JSON
            foreach my $d (@$pData) {
                my ($s, $e) = ($d->{start}, $d->{stop});
                my $mid = int( ( $s + $e ) / 2 );
                my $b   = int( ( $mid - $start ) / $bpPerBin );
                $b = 0 if ( $b < 0 );
                $bins[$b]++;
            }
        }
        elsif ( $data_type == $DATA_TYPE_ALIGN ) {
	        # Convert SAMTools output into JSON
	        foreach (@$pData) {
	        	chomp;
	        	my ($qname, $flag, $rname, $pos, $mapq, $cigar, undef, undef, undef, $seq, $qual, $tags) = split(/\t/);

	        	my $len = length($seq);
	        	my $s = $pos;
	        	my $e = $pos + $len;

				# Bin results
                my $mid = int( ( $s + $e ) / 2 );
                my $b   = int( ( $mid - $start ) / $bpPerBin );
                $b = 0 if ( $b < 0 );
                $bins[$b]++;
	        }
        }
        else {
        	print STDERR "JBrowse::Experiment::stats_regionFeatureDensities unknown data type for experiment $eid\n";
        	next;
        }
    }

    my ( $sum, $count );
    foreach my $x (@bins) {
        $sum += $x;
         #$max = $x if ( not defined $max or $x > $max ); # mdb removed 1/14/14 for BAM histograms
        $count++;
    }
    my $mean = 0;
    $mean = $sum / $count if ($count);
    my $max = $bpPerBin; # mdb added 1/14/14 for BAM histograms

    $self->render(json => {
        bins => \@bins,
        stats => { basesPerBin => $bpPerBin, max => $max, mean => $mean }
    });
}

sub data {
    my $self = shift;
    my $id = int($self->stash('eid'));
    my $chr = $self->stash('chr');
    my $data_type = $self->param('data_type');
    my $type = $self->param('type');
    my $gte = $self->param('gte');
    my $lte = $self->param('lte');
    my $transform = $self->param('transform');

    # Authenticate user and connect to the database
    my ($db, $user) = CoGe::Services::Auth::init($self);
    # unless ($user) {
    #     $self->render(json => {
    #         error => { Error => "User not logged in" }
    #     });
    #     return;
    # }       

    # Get experiment
    my $experiment = $db->resultset("Experiment")->find($id);
    unless (defined $experiment) {
        $self->render(json => {
            error => { Error => "Experiment not found" }
        });
        return;
    }

    # Check permissions
    unless ($user->is_admin() || $user->is_owner_editor(experiment => $id)) {
        $self->render(json => {
            error => { Auth => "Access denied" }
        }, status => 401);
        return;
    }

    my $exp_data_type = $experiment->data_type;
    my $filename = 'experiment' . ($exp_data_type == $DATA_TYPE_POLY ? '.vcf' : '.csv');
    $self->res->headers->content_disposition('attachment; filename=' . $filename . ';');
    $self->write('# experiment: ' . $experiment->name . "\n");
    $self->write("# chromosome: $chr\n");

    if ( !$exp_data_type || $exp_data_type == $DATA_TYPE_QUANT ) {
        if ($type) {
            $self->write("# search: type = $type");
            $self->write(", gte = $gte") if $gte;
            $self->write(", lte = $lte") if $lte;
            $self->write("\n");
        }
        $self->write("# transform: $transform\n") if $transform;
        my $cols = CoGe::Core::Experiment::get_fastbit_format()->{columns};
        my @columns = map { $_->{name} } @{$cols};
        $self->write('# columns: ');
        for (my $i=0; $i<scalar @columns; $i++) {
            $self->write(',') if $i;
            $self->write($columns[$i]);
        }
        $self->write("\n");

        my $lines = CoGe::Core::Experiment::query_data(
            eid => $id,
            data_type => $data_type,
            col => join(',', @columns),
            chr => $chr,
            type => $type,
            gte => $gte,
            lte => $lte,
        );
        my $score_column = CoGe::Core::Experiment::get_fastbit_score_column($data_type);
        my $log10 = log(10);
        foreach my $line (@{$lines}) {
            if ($transform) {
                my @tokens = split ',', $line;
                if ($transform eq 'Inflate') {
                    $tokens[$score_column] = 1;
                }
                elsif ($transform eq 'Log2') {
                    $tokens[$score_column] = log(1 + $tokens[$score_column]);
                }
                elsif ($transform eq 'Log10') {
                    $tokens[$score_column] = log(1 + $tokens[$score_column]) / $log10;
                }
                $line = join ',', @tokens;
            }
            $self->write($line);
            $self->write("\n");
        }
    }
    elsif ( $exp_data_type == $DATA_TYPE_POLY ) {
        my $type_names = $self->param('features');
        if ($type_names) {
            $self->write('# search: SNPs in ');
            $self->write($type_names);
            $self->write("\n");
        }
        my $type = $self->param('type');
        if ($type) {
            $self->write('# search: ');
            $self->write($type);
            $self->write("\n");
        }
        $self->write("#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\n");
        my $snps = $self->_snps;
        my $s = (index(@{$snps}[0], ', ') == -1 ? 1 : 2);
        foreach my $line (@{$snps}) {
            my @l = split(',', $line);
            $self->write(substr($l[0], 1, -1));
            $self->write("\t");
            $self->write($l[1]);
            $self->write("\t");
            $self->write(substr($l[4], $s, -1));
            $self->write("\t");
            $self->write(substr($l[5], $s, -1));
            $self->write("\t");
            $self->write(substr($l[6], $s, -1));
            $self->write("\t");
            $self->write($l[7]);
            $self->write("\t\t");
            $self->write(substr($l[8], $s, -1));
            $self->write("\t\n");
        }
    }
    $self->finish();
}

sub _get_experiments {
	my $db = shift;
	my $user = shift;
	my $eid = shift;
	my $gid = shift;
	my $nid = shift;

    my @all_experiments;
    if ($eid) {
        my $experiment = $db->resultset('Experiment')->find($eid);
        push @all_experiments, $experiment if $experiment;
    }
    elsif ($nid) {
        my $notebook = $db->resultset('List')->find($nid);
        push @all_experiments, $notebook->experiments if $notebook;
    }
    elsif ($gid) {
        my $genome = $db->resultset('Genome')->find($gid);
        push @all_experiments, $genome->experiments if $genome;
    }

    # Filter experiments based on permissions
    my @experiments;
    foreach my $e (@all_experiments) {
        if (!$e->restricted() || ($user && $user->has_access_to_experiment($e))) {
        	push @experiments, $e;
        }
        else {
            if ($user && $user->name) {
            	warn 'JBrowse::Experiment::_get_experiments access denied to experiment ' . $eid . ' for user ' . $user->name;
            }
            else {
                warn 'JBrowse::Experiment::_get_experiments access denied to experiment ' . $eid;
            }
        }
    }
    splice(@experiments, $MAX_EXPERIMENTS);
    return \@experiments;
}

sub histogram {
    my $self = shift;
    my $eid = $self->stash('eid');
    my $chr = $self->stash('chr');
    my $storage_path = get_experiment_path($eid);
    my $hist_file = "$storage_path/value1_$chr.hist";
    if (!-e $hist_file) {
        $chr = undef if $chr eq 'Any';
		my $result = CoGe::Core::Experiment::query_data(
			eid => $eid,
			col => 'value1',
			chr => $chr
		);
	    my $bins = CoGe::Accessory::histogram::_histogram_bins($result, 20);
	    my $counts = CoGe::Accessory::histogram::_histogram_frequency($result, $bins);
	    if (open my $fh, ">", $hist_file) {
    	    print {$fh} encode_json({
    	    	first => 0 + $bins->[0][0],
    	    	gap => $bins->[0][1] - $bins->[0][0],
    	    	counts => $counts
    	    });
    	    close $fh;
        }
        else {
            warn "error opening $hist_file";
        }
    }
    open(my $fh, $hist_file);
    my $hist = <$fh>;
    close($fh);
	$self->render(json => decode_json($hist));
}

sub query_data {
    my $self = shift;
    my $eid = $self->stash('eid');
    my $chr = $self->param('chr');
    $chr = undef if $chr eq 'All';
    my $type = $self->param('type');
    my $gte = $self->param('gte');
    my $lte = $self->param('lte');

    # Authenticate user and connect to the database
    my ($db, $user) = CoGe::Services::Auth::init($self);

	my $experiments = _get_experiments($db, $user, $eid);
	my $result = [];
	foreach my $experiment (@$experiments) { # this doesn't yet handle multiple experiments (i.e notebooks)
		$result = CoGe::Core::Experiment::query_data(
			eid => $eid,
			data_type => $experiment->data_type,
			chr => $chr,
			type => $type,
			gte => $gte,
			lte => $lte,
		);
	}
    $self->render(json => $result);
}

sub snp_overlaps_feature {
	my $loc = shift;
	my $features = shift;
	foreach my $feature (@$features) {
		if ($loc >= $feature->[1] && $loc <= $feature->[2]) {
			return 1;
		}
	}
	return 0;
}

sub snps {
    my $self = shift;
    my $results = $self->_snps;
    if ($results) {
        $self->render(json => $results);
    }
}

sub _snps {
    my $self = shift;
    my $eid = $self->stash('eid');
    my $chr = $self->stash('chr');
    $chr = undef if $chr eq 'Any';

    # Authenticate user and connect to the database
    my ($db, $user, $conf) = CoGe::Services::Auth::init($self);

	my $experiments = _get_experiments($db, $user, $eid);
    if (scalar @{$experiments} == 0) {
        $self->render(json => { error => 'User does not have permission to view this experiment' });
        return undef;
    }

	my $type_names = $self->param('features');
	if ($type_names) {
        my $snps;
        foreach my $experiment (@$experiments) { # this doesn't yet handle multiple experiments (i.e notebooks)
            $snps = CoGe::Core::Experiment::query_data(
                eid => $eid,
                data_type => $experiment->data_type,
                chr => $chr,
            );
        }

        my $dbh = $db->storage->dbh;

		my $type_ids;
		if ($type_names ne 'all') {
			$type_ids = feature_type_names_to_id($type_names, $dbh);
		}
	
		my $type = (split ',', $type_ids)[0];
		my $fi = CoGe::Services::API::JBrowse::FeatureIndex->new($experiments->[0]->genome_id, $type, $chr, $conf);
		my $features = $fi->get_features($dbh);
		my $hits = [];
	    foreach my $snp (@$snps) {
	    	my @tokens = split(',', $snp);
	    	if (snp_overlaps_feature(0 + $tokens[1], $features)) {
	    		push @$hits, $snp;
	    	}
	    }
	    return $hits;
	}
	elsif ($self->param('snp_type')) {
        my $cmdpath = catfile(CoGe::Accessory::Web::get_defaults()->{BINDIR}, 'snp_search', 'snp_search');
        my $storage_path = get_experiment_path($eid);
        opendir(my $dh, $storage_path);
        my @files = grep(/\.vcf$/,readdir($dh));
        closedir $dh;
        my $cmd = "$cmdpath $storage_path/" . $files[0] . ' ' . $self->stash('chr') . ' "' . $self->param('snp_type') . '"';
        warn $cmd;
        my @cmdOut = qx{$cmd};

        my $cmdStatus = $?;
        if ( $? != 0 ) {
            warn "CoGe::Services::API::JBrowse::Experiment: error $? executing command: $cmd";
        }
        my @lines;
        foreach (@cmdOut) {
            chomp;
            push @lines, $_;
        }
        return \@lines;
	}
    else {
        my $snps;
        foreach my $experiment (@$experiments) { # this doesn't yet handle multiple experiments (i.e notebooks)
            $snps = CoGe::Core::Experiment::query_data(
                eid => $eid,
                data_type => $experiment->data_type,
                chr => $chr,
            );
        }
        return $snps;
    }
}

sub features {
    my $self  = shift;
    my $eid   = $self->stash('eid');
    my $nid   = $self->stash('nid');
    my $gid   = $self->stash('gid');
    my $chr   = $self->stash('chr');
    my $start = $self->param('start');
    my $end   = $self->param('end');
    return unless (($eid or $nid or $gid) and defined $chr and defined $start and defined $end);

# mdb removed 11/6/15 COGE-678
#    if ( $end - $start + 1 > $MAX_WINDOW_SIZE ) {
#        print STDERR "experiment features maxed\n";
#        return qq{{ "features" : [ ] }};
#    }

    # Authenticate user and connect to the database
    my ($db, $user) = CoGe::Services::Auth::init($self);

	my $experiments = _get_experiments($db, $user, $eid, $gid, $nid);

    if (!@$experiments) {
        return $self->render(json => { features => [] });
    }

	# Query range for each experiment and build up json response - #TODO could parallelize this for multiple experiments
    my @results;
    foreach my $exp (@$experiments) {
        my $eid       = $exp->id;
        my $data_type = $exp->data_type;

        my $pData = CoGe::Core::Experiment::get_data(
            eid   => $eid,
            data_type  => $data_type,
            chr   => $chr,
            start => $start,
            end   => $end
        );

        if ( !$data_type || $data_type == $DATA_TYPE_QUANT ) {
            foreach my $d (@$pData) {
                #next if ($d->{value1} == 0 and $d->{value2} == 0); # mdb removed 1/15/15 for user Un-Sa - send zero values (for when "Show background" is enabled in JBrowse)
                my %result = (
                    id     => int($eid),
                    start  => $d->{start},
                    end    => $d->{stop},
                );
                $d->{strand} = -1 if ($d->{strand} == 0);
                $result{end} = $result{start} + 1 if ( $result{end} == $result{start} ); #FIXME revisit this
                $result{score} = $d->{strand} * $d->{value1};
                $result{score2} = $d->{value2} if (defined $d->{value2});
                $result{label} = $d->{label} if (defined $d->{label});
                push(@results, \%result);
            }
        }
        elsif ( $data_type == $DATA_TYPE_POLY ) {
            foreach my $d (@$pData) {
                my %result = (
                    id    => $eid,
                    name  => $d->{name},
                    type  => $d->{type},
                    start => $d->{start},
                    end   => $d->{stop},
                    ref   => $d->{ref},
                    alt   => $d->{alt},
                    score => $d->{qual},
                    info  => $d->{info}
                );
                $result{score2} = $d->{value2} if (defined $d->{value2});
                $result{label} = $d->{label} if (defined $d->{label});
                $result{name} = (( $d->{id} && $d->{id} ne '.' ) ? $d->{id} . ' ' : '')
                    . $d->{type} . ' ' . $d->{ref} . " > " . $d->{alt};
                $result{type} = $d->{type} . $d->{ref} . 'to' . $d->{alt}
                    if ( lc($d->{type}) eq 'snp' );
                push(@results, \%result);
            }
        }
        elsif ( $data_type == $DATA_TYPE_MARKER ) {
            foreach my $d (@$pData) {
                my ($name) = $d->{attr} =~ /ID\=([\w\.\-]+)\;/; # mdb added 4/24/14 for Amanda
                my %result = (
                    uniqueID => $d->{start} . '_' . $d->{stop},
                    type     => $d->{type},
                    start    => $d->{start},
                    end      => $d->{stop},
                    strand   => $d->{strand},
                    score    => $d->{value1},
                    attr     => $d->{attr},
                    name     => $name
                );
                $result{'strand'} = -1 if ($result{'strand'} == 0);
                $result{'stop'} = $result{'start'} + 1 if ( $result{'stop'} == $result{'start'} ); #FIXME revisit this
                $result{'value1'} = $result{'strand'} * $result{'value1'};
                push(@results, \%result);
            }
        }
        elsif ( $data_type == $DATA_TYPE_ALIGN ) {
	        # Convert SAMTools output into JSON
	        if ($nid) { # return read count if being displayed in a notebook
	           # Bin the read counts by position
                my %bins;
                foreach (@$pData) {
                    chomp;
                    my (undef, undef, undef, $pos, $mapq, undef, undef, undef, undef, $seq) = split(/\t/);
                    for (my $i = $pos; $i < $pos+length($seq); $i++) {
                        $bins{$i}++;
                    }
                }
                # Convert to intervals
                my ($start, $stop, $lastCount);
                foreach my $pos (sort {$a <=> $b} keys %bins) {
                    my $count = $bins{$pos};
                    if (!defined $start || ($pos-$stop > 1) || $lastCount != $count) {
                        if (defined $start) {
                            $stop++;
                            push(@results, { 
                                "id"    => $eid, 
                                "start" => $start, 
                                "end"   => $stop, 
                                "score" => $lastCount 
                            });
                        }
                        $start = $pos;
                    }
                    $lastCount = $count;
                    $stop = $pos;
               }
               if (defined $start and $start != $stop) { # do last interval
                    $stop++;
                    push(@results, { 
                        "id"    => $eid, 
                        "start" => $start, 
                        "end"   => $stop, 
                        "score" => $lastCount 
                    });    
                }
	        }
	        else { # else return list reads with qual and seq
    	        foreach (@$pData) {
    	        	chomp;
    	        	my ($qname, $flag, $rname, $pos, $mapq, $cigar, undef, undef, undef, $seq, $qual, $tags) = split(/\t/);

    	        	my $len = length($seq);
    	        	my $start = $pos;
    	        	my $end = $pos + $len;
    	        	my $strand = ($flag & 0x10 ? '-1' : '1');
    	        	#TODO reverse complement sequence if neg strand?
    	        	$qual = join(' ', map { $_ - $QUAL_ENCODING_OFFSET } unpack("C*", $qual));

                    push(@results, { 
                        "uniqueID" => "$qname", 
                        "name"     => "$qname", 
                        "start"    => $start, 
                        "end"      => $end, 
                        "strand"   => $strand, 
                        "score"    => $mapq, 
                        "seq"      => "$seq", 
                        "qual"     => "$qual", 
                        "Seq length" => $len, 
                        "CIGAR"    => "$cigar" 
                    });      	        	
    	        }
	        }
        }
        else {
        	print STDERR "JBrowse::Experiment::features unknown data type $data_type for experiment $eid\n";
        	next;
        }
    }

    $self->render(json => { "features" => \@results });
}

1;