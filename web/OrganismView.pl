#! /usr/bin/perl -w
use strict;
use CGI;
use CGI::Carp 'fatalsToBrowser';
use CoGe::Accessory::LogUser;
use CoGe::Accessory::Web;
use HTML::Template;
use Data::Dumper;
use CGI::Ajax;
use CoGeX;
use Benchmark;
use File::Path;
use Digest::MD5 qw(md5_base64);
use Benchmark qw(:all);
use Statistics::Basic::Mean;
no warnings 'redefine';

use vars qw($P $DBNAME $DBHOST $DBPORT $DBUSER $DBPASS $connstr $DATE $DEBUG $TEMPDIR $TEMPURL $USER $FORM $coge $HISTOGRAM %FUNCTION $P $COOKIE_NAME);
$P = CoGe::Accessory::Web::get_defaults("$ENV{HOME}/coge.conf");
$ENV{PATH} = $P->{COGEDIR};
$ENV{irodsEnvFile} = "/var/www/.irods/.irodsEnv";

# set this to 1 to print verbose messages to logs
$DEBUG = 0;
$TEMPDIR = $P->{TEMPDIR}."OrgView";
$TEMPURL = $P->{TEMPURL}."OrgView";

mkpath ($TEMPDIR, 0,0777) unless -d $TEMPDIR;

$HISTOGRAM = $P->{HISTOGRAM};

$| = 1; # turn off buffering
$DATE = sprintf( "%04d-%02d-%02d %02d:%02d:%02d",
		 sub { ($_[5]+1900, $_[4]+1, $_[3]),$_[2],$_[1],$_[0] }->(localtime));

$FORM = new CGI;


$DBNAME = $P->{DBNAME};
$DBHOST = $P->{DBHOST};
$DBPORT = $P->{DBPORT};
$DBUSER = $P->{DBUSER};
$DBPASS = $P->{DBPASS};
$connstr = "dbi:mysql:dbname=".$DBNAME.";host=".$DBHOST.";port=".$DBPORT;
$coge = CoGeX->connect($connstr, $DBUSER, $DBPASS );
#$coge->storage->debugobj(new DBIxProfiler());
#$coge->storage->debug(1);

$COOKIE_NAME = $P->{COOKIE_NAME};

my ($cas_ticket) =$FORM->param('ticket');
$USER = undef;
($USER) = CoGe::Accessory::Web->login_cas(ticket=>$cas_ticket, coge=>$coge, this_url=>$FORM->url()) if($cas_ticket);
($USER) = CoGe::Accessory::LogUser->get_user(cookie_name=>$COOKIE_NAME,coge=>$coge) unless $USER;

#my $pj = new CGI::Ajax(
%FUNCTION = (
	     get_dataset_groups=>\&get_dataset_groups,
	     get_dataset_group_info=>\&get_dataset_group_info,
	     get_dataset => \&get_dataset,
	     get_dataset_info => \&get_dataset_info,
	     get_dataset_chr_info => \&get_dataset_chr_info,
	     gen_data => \&gen_data,
	     get_orgs => \&get_orgs,
	     get_org_info=>\&get_org_info,
	     get_recent_orgs=>\&get_recent_orgs,
	     get_start_stop=>\&get_start_stop,
	     get_feature_counts => \&get_feature_counts,
	     get_gc_for_chromosome=> \&get_gc_for_chromosome,
	     get_gc_for_noncoding=> \&get_gc_for_noncoding,
	     get_gc_for_feature_type =>\&get_gc_for_feature_type,
	     get_codon_usage=>\&get_codon_usage,
	     get_aa_usage=>\&get_aa_usage,
	     get_wobble_gc=>\&get_wobble_gc,
	     get_wobble_gc_diff=>\&get_wobble_gc_diff,
	     get_total_length_for_ds=>\&get_total_length_for_ds,
	     update_genomelist=>\&update_genomelist,
	     parse_for_GenoList=>\&parse_for_GenoList,
	     get_genome_list_for_org=>\&get_genome_list_for_org,
	     add_to_irods=>\&add_to_irods,
	     make_genome_public=>\&make_genome_public,
	     make_genome_private=>\&make_genome_private,
	    );
my $pj = new CGI::Ajax(%FUNCTION);
$pj->JSDEBUG(0);
$pj->DEBUG(0);
if ($FORM->param('jquery_ajax'))
  {
    dispatch();
  }
else
  {
    print $pj->build_html($FORM, \&gen_html);
  }
#print "Content-Type: text/html\n\n";print gen_html($FORM);

sub dispatch
{
    my %args = $FORM->Vars;
    my $fname = $args{'fname'};
    if($fname)
    {
	#my %args = $cgi->Vars;
	#print STDERR Dumper \%args;
	if($args{args}){
	    my @args_list = split( /,/, $args{args} );
	    print $FORM->header, $FUNCTION{$fname}->(@args_list);
       	}
	else{
	    print $FORM->header, $FUNCTION{$fname}->(%args);
	}
    }
#    else{
#	print $FORM->header, gen_html();
#    }
}

sub parse_for_GenoList
  {
	my $genomelist = shift;
	my $url = "GenomeList.pl?dsgid=$genomelist";
	return $url;
 }

sub gen_html
  {
    my $html;
    my ($body, $seq_names, $seqs) = gen_body();
    my $template = HTML::Template->new(filename=>$P->{TMPLDIR}.'generic_page.tmpl');
    #	$template->param(TITLE=>'Organism Overview');
    $template->param(PAGE_TITLE=>'OrgView');
    $template->param(HEAD=>qq{});
    $template->param(HELP=>"/wiki/index.php?title=OrganismView");
    my $name = $USER->user_name;
    $name = $USER->first_name if $USER->first_name;
    $name .= " ".$USER->last_name if $USER->first_name && $USER->last_name;
    $template->param(USER=>$name);
    $template->param(BOX_NAME=>"Search for organisms and genomes");
    $template->param(LOGON=>1) unless $USER->user_name eq "public";
    $template->param(DATE=>$DATE);
    $template->param(LOGO_PNG=>"OrganismView-logo.png");
    $template->param(BODY=>$body);
    #	$template->param(ADJUST_BOX=>1);
    $html .= $template->output;
    return $html;
  }

sub gen_body
  {
    my $form = shift || $FORM;
    my $template = HTML::Template->new(filename=>$P->{TMPLDIR}.'OrganismView.tmpl');
    my $org_name = $form->param('org_name');
    my $desc = $form->param('org_desc');
    my $oid = $form->param('oid');
    my $org = $coge->resultset('Organism')->resolve($oid) if $oid;
    my $dsname = $form->param('dsname');
    my $dsid = $form->param('dsid');
    my $dsgid = $form->param('dsgid');
    my ($dsg) = $coge->resultset('DatasetGroup')->find($dsgid) if $dsgid;
    $org = $dsg->organism if $dsg;

    $org_name = $org->name if $org;
    $org_name = "Search" unless $org_name;
    $template->param(ORG_NAME=>$org_name) if $org_name;
    $desc = "Search" unless $desc;
    $template->param(ORG_DESC=>$desc) if $desc;
    $org_name = "" if $org_name =~ /Search/;
    my ($org_list, $org_count) = get_orgs(name=>$org_name, oid=>$oid, dsgid=>$dsgid);
    $template->param(ORG_LIST=>$org_list);
    $template->param(ORG_COUNT=>$org_count);
    #$template->param(RECENT=>get_recent_orgs());
    my ($ds) = $coge->resultset('Dataset')->resolve($dsid) if $dsid;
    $dsname = $ds->name if $ds;
    $dsname = "Search" unless $dsname;
    $template->param(DS_NAME=>$dsname);
    $dsname = "" if $dsname =~ /Search/;
    my ($dslist,$dscount) = get_dataset(dsname=>$dsname, dsid=>$dsid) if $dsname;
    $template->param(DS_LIST=>$dslist) if $dslist;
    $template->param(DS_COUNT=>$dscount) if $dscount;
    my $dsginfo = "<input type=hidden id=gstid>";
    $dsginfo .= $dsgid ? "<input type=hidden id=dsg_id value=$dsgid>" : "<input type=hidden id=dsg_id>";
    $template->param(DSG_INFO=>$dsginfo);
    return $template->output;
  }

sub make_genome_public
  {
    my %opts = @_;
    my $dsgid = $opts{dsgid};
    return "No DSGID specified" unless $dsgid;
    return "Permission denied." unless $USER->is_admin || $USER->is_owner(dsg=>$dsgid);
    my $dsg = $coge->resultset('DatasetGroup')->find($dsgid);
    $dsg->restricted(0);
    $dsg->update;
    foreach my $ds ($dsg->datasets)
      {
	$ds->restricted(0);
	$ds->update;
      }
    return 1;
  }

sub make_genome_private
  {
    my %opts = @_;
    my $dsgid = $opts{dsgid};
    return "No DSGID specified" unless $dsgid;
    return "Permission denied." unless $USER->is_admin || $USER->is_owner(dsg=>$dsgid);
    my $dsg = $coge->resultset('DatasetGroup')->find($dsgid);
    $dsg->restricted(1);
    $dsg->update;
    foreach my $ds ($dsg->datasets)
      {
	$ds->restricted(1);
	$ds->update;
      }
    return 1;
  }

sub get_recent_orgs
  {
    my %opts = @_;
    my $limit = $opts{limit} || 100;
    my @db = $coge->resultset("Dataset")->search({restricted=>0},
						 {
						  distinct=>"organism.name",
						  join=>"organism",
						  order_by=>"me.date desc",
						  rows=>$limit}
						);
   
 my $i=0;

    my @opts;
    my %org_names;
    foreach my $item (@db)
      {
		$i++;
	my $date = $item->date;
	$date =~ s/\s.*//;
	#next if $USER->user_name =~ /public/i && $item->organism->restricted;
	next if $org_names{$item->organism->name};
	$org_names{$item->organism->name}=1;
	push @opts, "<OPTION value=\"".$item->organism->id."\">".$date." ".$item->organism->name." (id".$item->organism->id.") "."</OPTION>";
      }
    my $html;
#    $html .= qq{<FONT CLASS ="small">Organism count: }.scalar @opts.qq{</FONT>\n<BR>\n};
    unless (@opts) 
      {
	$html .=  qq{<input type = hidden name="org_id" id="org_id">};
	return $html;
      }
	print STDERR $i.'+++++++++++++\n';
    $html .= qq{<SELECT class="ui-widget-content ui-corner-all" id="recent_org_id" SIZE="5" MULTIPLE onChange="recent_dataset_chain()" >\n};
    $html .= join ("\n", @opts);
    $html .= "\n</SELECT>\n";
    $html =~ s/OPTION/OPTION SELECTED/;
    return $html;
  }


sub get_orgs
  {
    my %opts = @_;
    my $name = $opts{name};
    my $desc = $opts{desc};
    my $oid = $opts{oid};
    my $dsgid = $opts{dsgid};
    my $dsg = $coge->resultset('DatasetGroup')->find($dsgid) if $dsgid;
    if($dsg && $dsg->restricted){
	if(!$USER->has_access_to_genome($dsg)){
	    $dsg=undef;
	}
    }
    my @db;
    if ($name)
      {
	@db = $coge->resultset("Organism")->search({name=>{like=>"%".$name."%"}});
      }
    elsif($desc)
      {
	@db = $coge->resultset("Organism")->search({description=>{like=>"%".$desc."%"}});
      }
    else
      {
	@db = $coge->resultset("Organism")->all;
      }

    my @opts;
    foreach my $item (sort {uc($a->name) cmp uc($b->name)} @db)
      {
	my $option = "<OPTION value=\"".$item->id."\"";
	$option .= " SELECTED" if $oid && $item->id == $oid;
	$option .= " SELECTED" if $dsg && $item->id == $dsg->organism->id;
	my $name = $item->name;
	if (length($name) > 50)
	  {
	    $name = substr($name, 0,50)."...";
	  }
	$option .= ">".$name." (id".$item->id.")</OPTION>";
	push @opts, $option;
      }
    my $html;
    unless (@opts) 
      {
	$html .=  qq{<input type = hidden name="org_id" id="org_id">No organisms found};
	return $html,0;
      }

    $html .= qq{<SELECT class="ui-widget-content ui-corner-all" id="org_id" SIZE="5" MULTIPLE onChange="get_org_info_chain()" >\n};
    $html .= join ("\n", @opts);
    $html .= "\n</SELECT>\n";
    $html =~ s/OPTION/OPTION SELECTED/ unless $html =~ /SELECTED/;
    my $opts = "?";
    $opts .= "name=$name;" if $name;
    $opts .= "desc=$desc;" if $desc;
    $opts .= "oid=$oid;" if $oid;
    $opts .= "dsgid=$dsgid;" if $dsgid;
    $html .= qq{<br><span class='link small' onclick="window.open('get_org_list.pl$opts');">Download Organism List</span>};
    return $html, scalar @opts;
  }


sub update_genomelist
{
	my %opts = @_;
	my $genome_id   = $opts{genomeid};
	return unless $genome_id;
	my $dsg = $coge->resultset("DatasetGroup")->find($genome_id);
	my $genome_name;
	$genome_name = $dsg->name;
	$genome_name = $dsg->organism->name unless $genome_name;
	$genome_name .= " (v". $dsg->version.")";
	return $genome_name,$genome_id;
}

sub get_org_info
  {
    my %opts = @_;
    my $oid = $opts{oid};
    return " " unless $oid;
    my $org = $coge->resultset("Organism")->find($oid);
    return "Unable to find an organism for id: $oid\n" unless $org;
    my $html;# = qq{<div class="backbox small">};
    $html.= "<span class=alert>Private Organism!  Authorized Use Only!</span><br>" if $org->restricted;
    $html .= qq{<table class='small annotation_table'>};
    $html .= qq{<tr><td>Name:};
    $html .= qq{<td>}.$org->name;

    if ($org->description)
      {
	$html .= qq{<tr><td>Description:<td>};

	foreach my $item (split/;/, $org->description)
	  {
	    $item =~ s/^\s+//;
	    $item =~ s/\s+$//;
	    $html .= "<a href=OrganismView.pl?org_desc=$item>$item</a>;"
	  }
      }
    $html .= "<tr><td>Links:<td><a href='OrganismView.pl?oid=$oid' target=_new>OrganismView</a>&nbsp|&nbsp<a href='CodeOn.pl?oid=$oid' target=_new>CodeOn</a>";
    $html .= "<tr><Td>Search:<td>";
    my $search_term = $org->name;
    $html .= qq{<img onclick="window.open('http://www.ncbi.nlm.nih.gov/taxonomy?term=$search_term')" src = "picts/other/NCBI-icon.png" title="NCBI" class=link>&nbsp};
    $html .= qq{<img onclick="window.open('http://en.wikipedia.org/w/index.php?title=Special%3ASearch&search=$search_term')" src = "picts/other/wikipedia-icon.png" title="Wikipedia" class=link>&nbsp};
    $search_term =~ s/\s+/\+/g;
    $html .= qq{<img onclick="window.open('http://www.google.com/search?q=$search_term')" src="picts/other/google-icon.png" title="Google" class=link>};
    $html .= "</table>";
#    $html .= "</div>";
    return $html;
  }

sub get_genome_list_for_org
{
  my %opts = @_;
  my $oid = $opts{oid};
  my $org = $coge->resultset("Organism")->find($oid);
  my @opts;
  if ($org)
    {
      my @dsg;
      foreach my $dsg ($org->dataset_groups)
	{
	  next if $dsg->restricted && !$USER->has_access_to_genome($dsg);
	  $dsg->name($org->name) unless $dsg->name;
    	  push @dsg, $dsg;
	}
      @opts = map {$_->id."%%".$_->name." (v".$_->version.", dsgid".$_->id. "): ". $_->genomic_sequence_type->name} sort {$b->version <=> $a->version || $a->type->id <=> $b->type->id || $a->name cmp $b->name || $b->id cmp $a->id} @dsg;
    }

  my $res = join ("&&", @opts);
}

sub get_dataset_groups
    {
      my %opts = @_;
      my $oid = $opts{oid};
      my $dsgid = $opts{dsgid};
      my $org = $coge->resultset("Organism")->find($oid);
      my @opts;
      my %selected;
      $selected{$dsgid} = "SELECTED" if $dsgid;
      if ($org)
	{
	  my @dsg;
	  foreach my $dsg ($org->dataset_groups)
	    {
	      next if $dsg->restricted && !$USER->has_access_to_genome($dsg);
	      push @dsg, $dsg
	    }
	  foreach my $dsg (@dsg)
	    {
	      $dsg->name($org->name) unless $dsg->name;
	      $selected{$dsg->id} = " " unless $selected{$dsg->id};
	    }
	  @opts = map {"<OPTION value=\"".$_->id."\" ".$selected{$_->id} .">".$_->name." (v".$_->version.", dsgid".$_->id. "): ". $_->genomic_sequence_type->name."</OPTION>"} sort {$b->version <=> $a->version || $a->type->id <=> $b->type->id || $b->id <=> $a->id} @dsg;
	}
      my $html;
      if (@opts) 
      {
#	$html = qq{<FONT CLASS ="small">Dataset group count: }.scalar (@opts).qq{</FONT>\n<BR>\n};
	$html .= qq{<SELECT class="ui-widget-content ui-corner-all" id="dsg_id" SIZE="5" MULTIPLE onChange="get_dataset_group_info(['args__dsgid','dsg_id'],[dataset_chain]);" >\n};
	$html .= join ("\n", @opts);
	$html .= qq{\n</SELECT><br/><br/>	<span class="ui-button ui-corner-all" id=all onClick="add_all_genomes(); ">Add all to Genome List</span><br/>\n};
	$html =~ s/OPTION/OPTION SELECTED/ unless $html =~ /SELECTED/i;
      }
    else
      {
	$html .=  qq{<input type = hidden name="dsg_id" id="dsg_id">};
      }
      return $html, scalar @opts;
    }

sub add_to_irods
  {
    my %opts = @_;
    my $dsgid = $opts{dsgid};
    my $dsg = $coge->resultset('DatasetGroup')->find($dsgid);
    my $add_to_irods_bin = $P->{BINDIR}."/irods/add_to_irods.pl";
    my $cmd = $add_to_irods_bin." -file ".$dsg->file_path;
    my $new_name = $dsg->organism->name." ".$dsg->id.".faa";
    $cmd .= " -new_name '$new_name'";
    $cmd .= " -dir collections";
    $cmd .= " -tag 'organism=".$dsg->organism->name."'";
    $cmd .= " -tag version=".$dsg->version;
    $cmd .= " -tag 'sequence_type=".$dsg->sequence_type->name."'";
    my ($ds) = $dsg->datasets;
    $cmd .= " -tag 'source_name=".$ds->name."'";
    $cmd .= " -tag 'source_link=".$ds->link."'" if $ds->link;
    $cmd .= " -tag 'imported_from=CoGe: http://genomevolution.org/CoGe/OrganismView.pl?dsgid=$dsgid'";
    system($cmd);
    print STDERR $cmd;
    #return $cmd;
    return "Complete!"
  }

sub get_dataset_group_info
  {
    my %opts = @_;
    my $dsgid = $opts{dsgid};
    return " " unless $dsgid;
    my $dsg = $coge->resultset("DatasetGroup")->find($dsgid);
    return "Unable to get dataset_group object for id: $dsgid" unless $dsg;
    my $html;# = qq{<div style="overflow:auto; max-height:78px">};
    $html.= "<span class='alert large'>Private Genome!  Authorized Use Only!</span><br>" if $dsg->restricted;
    $html .= "&nbsp&nbsp&nbsp<span class=alert>You are a CoGe Admin.  Use your power wisely</span><br>" if $USER->is_admin;
    $html .= "&nbsp&nbsp&nbsp<span class=alert>You are the owner of this genome.</span><br>" if $USER->is_owner(dsg=>$dsg);
    my $total_length = $dsg->length;
#    my $chr_num = $dsg->genomic_sequences->count(); 
    my $chr_num = $dsg->chromosome_count();
    $html .= qq{<table>};
    $html .= "<tr valign=top><td><table class='small annotation_table'>";
    $html .= qq{<tr><td>Name:</td><td>}.$dsg->name.qq{</td></tr>} if $dsg->name;
    $html .= qq{<tr><td>Description:</td><td>}.$dsg->description.qq{</td></tr>} if $dsg->description;
    $html .= qq{<tr><td>Chromosome count: <td>}.commify($chr_num).qq{</td></tr>};
    my $gstid = $dsg->genomic_sequence_type->id;
    $html .= qq{<tr><td>Sequence type: <td>}.$dsg->genomic_sequence_type->name.qq{ (gstid$gstid)<input type=hidden id=gstid value=}.$gstid.qq{></td></tr>};
    $html .= qq{<tr><td>Length: </td>};
    $html .= qq{<td><div style="float: left;"> }.commify($total_length)." bp </div>";
    my $gc = $total_length < 10000000 && $chr_num < 500 ? get_gc_for_chromosome(dsgid=>$dsgid): 0;
    $gc = $gc ? $gc : qq{  <div style="float: left; text-indent: 1em;" id=datasetgroup_gc class="link" onclick="gen_data(['args__loading...'],['datasetgroup_gc']);\$('#datasetgroup_gc').removeClass('link'); get_gc_for_chromosome(['args__dsgid','dsg_id','args__gstid', 'gstid'],['datasetgroup_gc']);">  Click for percent GC content</div><br/>};
    $html .= "$gc</td></tr>";

    $html .= qq{
<tr><td>Noncoding sequence:<td><div id=dsg_noncoding_gc class="link" onclick = "gen_data(['args__loading...'],['dsg_noncoding_gc']);\$('#dsg_noncoding_gc').removeClass('link');  get_gc_for_noncoding(['args__dsgid','dsg_id','args__gstid', 'gstid'],['dsg_noncoding_gc']);">Click for percent GC content</div></td></tr> 
} if $total_length;
    my $seq_file = $dsg->file_path;
    $seq_file =~ s/\/opt\/apache2?//i;
    $html .= qq{<TR><TD>Download:</td>};
    $html .= qq{<td>};
    $html .= qq{<a class=link href='$seq_file' target="_new">Fasta Sequences</a>};
    $html .= qq{&nbsp|&nbsp};
    $html .= qq{<a href='coge_gff.pl?dsgid=$dsgid' target=_new>GFF Names Only</a>};
    $html .= qq{&nbsp|&nbsp};
    $html .= qq{<a href='coge_gff.pl?dsgid=$dsgid;annos=1' target=_new>GFF Names and Annotations</a>};
    $html .= qq{</td></tr>};

    $html .= "<tr><td>Links:</td>";
    $html .= qq{<td>};
    $html .= "<a href='OrganismView.pl?dsgid=$dsgid' target=_new>OrganismView</a>&nbsp|&nbsp<a href='CodeOn.pl?dsgid=$dsgid' target=_new>CodeOn</a>";
    $html .= qq{&nbsp|&nbsp};
    $html .= qq{<span class='link' onclick="window.open('SynMap.pl?dsgid1=$dsgid;dsgid2=$dsgid');">SynMap</span>};
    $html .= qq{&nbsp|&nbsp};
    $html .= qq{<span class='link' onclick="window.open('CoGeBlast.pl?dsgid=$dsgid');">CoGeBlast</span>};
    $html .= qq{&nbsp|&nbsp};
    $html .= qq{<span id=irods class='link' onclick="gen_data(['args__loading...'],['irods']);add_to_irods(['args__dsgid','args__$dsgid'],['irods']);">Send To iPlant Data Store</span>};
    $html .= "</td></tr>";

	
	
    my $feat_string = qq{
<tr><td><div id=dsg_feature_count class="small link" onclick="gen_data(['args__loading...'],['dsg_features']); get_feature_counts(['args__dsgid','dsg_id', 'args__gstid','gstid'],['dsg_features']);" >Click for Features</div>};
    $html .= $feat_string;
    $html .= qq{<tr><td colspan=2><div><span class="ui-button ui-corner-all" onClick="update_genomelist(['args__genomeid','args__$dsgid'],[add_to_genomelist]);\$('#geno_list').dialog('option', 'width', 500).dialog('open');">Add to Genome List</span>};
    if ($USER->is_owner(dsg=>$dsgid) || $USER->is_admin)
      {
	$html .= qq{<span class="ui-button ui-corner-all ui-button-go" onClick="make_dsg_public('$dsgid')">Make Genome Public</span>} if $dsg->restricted;
	$html .= qq{<span class="ui-button ui-corner-all ui-button-go" onClick="make_dsg_private('$dsgid')">Make Genome Private</span>} if !$dsg->restricted;
	my $users_with_access = join (", ", map {"<span class=link onclick=window.open('Groups.pl?ugid=".$_->id."')>".$_->name."</span>"} $dsg->user_groups);
	$html .= "User Groups with Access: $users_with_access" if $users_with_access;
      }
    $html .= qq{</div></td></tr>} ;
    $html .= "</table></td>";
    $html .= qq{<td id=dsg_features></td>};
    $html .= "</table>";
    return $html;
  }
  
sub get_dataset
  {
    my %opts = @_;
    my $dsgid = $opts{dsgid};
    my $dsname = $opts{dsname};
    my $dsid = $opts{dsid};
    return "<hidden id='ds_id'>",0 unless  $dsid || $dsname|| $dsgid;
    if ($dsid)
      {
	my ($ds) = $coge->resultset('Dataset')->resolve($dsid);
	$dsname = $ds->name;
      }
    my $html; 
    my @opts;
    if ($dsgid)
      {
	my $dsg = $coge->resultset("DatasetGroup")->find($dsgid);
	@opts = map {"<OPTION value=\"".$_->id."\">".$_->name. " (v".$_->version.", dsid".$_->id.")</OPTION>"} sort {$b->version <=> $a->version || $a->name cmp $b->name} $dsg->datasets if $dsg;

	}
    elsif ($dsname)
      {
	my @ds = $coge->resultset("Dataset")->search({name=>{like=>"%".$dsname."%"}});

	my %orgs;
	foreach my $item (sort {$b->version <=> $a->version || uc($a->name) cmp uc($b->name)} @ds)
	  {
	    next if $item->restricted && !$USER->has_access_to_dataset($item);
	    my $option = "<OPTION value=\"".$item->id."\">".$item->name."(v".$item->version.", id".$item->id.")</OPTION>";
	    if ($dsid && $dsid == $item->id)
	      {
		$option =~ s/(<OPTION)/$1 selected/;
	      }
	    push @opts, $option;
	    $orgs{$item->organism->id}=$item->organism;
	  }
      }
    if (@opts) 
      {
	$html .= qq{<SELECT class="ui-widget-content ui-corner-all" id="ds_id" SIZE="5" MULTIPLE onChange="dataset_info_chain()" >\n};
	$html .= join ("\n", @opts);
	$html .= "\n</SELECT>\n";
	$html =~ s/OPTION/OPTION SELECTED/ unless $dsid;
      }
    else
      {
	$html .=  qq{<input type = hidden name="ds_id" id="ds_id">};
      }
    return $html, scalar @opts;
  }

sub get_dataset_info
  {
    my $dsd = shift;
    my $chr_num_limit = 500;
    return qq{<input type="hidden" id="chr" value="">}, " ",0 unless ($dsd); # error flag for empty dataset

    my $ds = $coge->resultset("Dataset")->find($dsd);
    my $html = "";
    return "unable to find dataset object for id: $dsd"  unless $ds;
    $html .= "<span class='alert large'>Private Dataset!  Authorized Use Only!</span><br>" if $ds->restricted;
    $html .= "<table>";
    $html .= "<tr valign=top><td><table class=\"small annotation_table\">";
    my $dataset = $ds->name;
    $dataset .= ": ". $ds->description if $ds->description;
    $dataset = " <a href=\"".$ds->link."\" target=_new\>".$dataset."</a>" if $ds->link;
    my $source_name = $ds->data_source->name ;
    $source_name.=": ". $ds->data_source->description if $ds->data_source->description;
    my $link = $ds->data_source->link;

    $link = "http://".$link if ($link && $link !~ /http/);
    $source_name = "<a href =\"".$link."\" target=_new\>".$source_name."</a>" if $ds->data_source->link;
    $html .= qq{<tr><td>Name: <td>$dataset}."\n";
    $html .= qq{<TR><TD>Data Source: <TD>$source_name (id}.$ds->data_source->id.qq{)}."\n";
    $html .= qq{<tr><td>Version: <td>}.$ds->version."\n";
    $html .= qq{<tr><td>Organism:<td class="link"><a href="OrganismView.pl?oid=}.$ds->organism->id.qq{" target=_new>}.$ds->organism->name."</a>\n";
    $html .= qq{<tr><td>Date deposited: <td>}.$ds->date."\n";


    my $html2;
    my $total_length = $ds->total_length(ftid=>4);
    my $chr_num = $ds->chromosome_count(ftid=>4);

    #working here.  Need to deal with large number of chromosomes (e.g. > 1000.  Perl object creation is killing performance)
    my %chr;
    map{$chr{$_->chromosome}={length=>$_->stop}} ($ds->get_chromosomes(ftid=>4, length=>1, limit=>$chr_num_limit)); #the chromosome feature type in coge is 301
    my $count = 100000;
    foreach my $item (sort keys %chr)
      {
	my ($num) = $item=~/(\d+)/;
	$num = $count unless $num;
	$chr{$item}{num} = $num;
	$count++;
      }
    my @chr = $chr_num > $chr_num_limit ? sort {$chr{$b}{length} <=> $chr{$a}{length}} keys %chr
      : sort {$chr{$a}{num} <=> $chr{$b}{num} || $a cmp $b}keys %chr;
    if (@chr)
      {
	my $size = scalar @chr;
	$size = 5 if $size > 5;
	my $select;
	$select .= qq{<SELECT class="ui-widget-content ui-corner-all" id="chr" size =$size onChange="dataset_chr_info_chain()" >\n};
	$select .= join ("\n", map {"<OPTION value=\"$_\">".$_." (".commify($chr{$_}{length})." bp)</OPTION>"} @chr)."\n";
	$select =~ s/OPTION/OPTION SELECTED/;
	$select .= "\n</SELECT>\n";

	$html2 .= $select;
      }
    else {
      $html2 .= qq{<input type="hidden" id="chr" value="">};
      $html2 .= "<tr><td>No chromosomes";
    }
    $html .= "<tr><td>Chromosome count:<td><div style=\"float: left;\">".commify($chr_num);
    $html .= "<tr><td>Total length:<td><div style=\"float: left;\">".commify($total_length)." bp ";
    my $gc = $total_length < 10000000 && $chr_num < $chr_num_limit ? get_gc_for_chromosome(dsid=>$ds->id): 0;
    $gc = $gc ? $gc : qq{  </div><div style="float: left; text-indent: 1em;" id=dataset_gc class="link" onclick="gen_data(['args__loading...'],['dataset_gc']);\$('#dataset_gc').removeClass('link'); get_gc_for_chromosome(['args__dsid','ds_id','args__gstid', 'gstid'],['dataset_gc']);">  Click for percent GC content</div>} if $total_length;
    $html .= $gc if $gc;
    $html .= qq{<tr><td>Links:</td>};
    $html .= "<td>";
    $html .= "<a href='OrganismView.pl?dsid=$dsd' target=_new>OrganismView</a>";
    $html .= qq{</td></tr>};
    my $feat_string = qq{
<tr><td><div id=ds_feature_count class="small link" onclick="gen_data(['args__loading...'],['ds_features']);get_feature_counts(['args__dsid','ds_id','args__gstid', 'gstid'],['ds_features']);" >Click for Features</div></td></tr>};
    $html .= $feat_string;

    $html .= qq{</table></td>};
    $html .= qq{<td id=ds_features></td>};
    $html .= qq{</table>};

    my $chr_count = $chr_num;
    $chr_count .= " <span class=alert>Only $chr_num_limit largest listed</span>" if ($chr_count >$chr_num_limit); 
    return $html, $html2, $chr_count;
  }

sub get_dataset_chr_info
  {
    my $dsid = shift;
    my $chr = shift;
    my $dsgid = shift;
    $dsgid = 0 unless defined $dsgid;
    $dsid = 0 unless $dsid;
    unless ($dsid && defined $chr) # error flag for empty dataset
	{
		return "", "", "";
	}
    my $start = "'start'";
    my $stop = "'stop'";
    my $html .= "<table>";
    $html .= "<tr valign=top><td><table class=\"small annotation_table\">";
    my $ds = $coge->resultset("Dataset")->find($dsid);
    return $html unless $ds;
    my $length = 0;
    $length = $ds->last_chromosome_position($chr) if defined $chr;
    my $gc = $length < 10000000? get_gc_for_chromosome(dsid=>$ds->id, chr=>$chr): 0;
    $gc = $gc ? $gc : qq{<div style="float: left; text-indent: 1em;" id=chromosome_gc class="link" onclick="\$('#chromosome_gc').removeClass('link'); get_gc_for_chromosome(['args__dsid','ds_id','args__chr','chr','args__gstid', 'gstid'],['chromosome_gc']);">Click for percent GC content</div>};
    $length = commify($length)." bp ";
    $html .= qq{
<tr><td>Chromosome:</td><td>$chr</td></tr>
<tr><td>Nucleotides:</td><td>$length</td><td>$gc</td></tr>
};

    $html .= qq{
<tr><td>Noncoding sequence:<td colspan=2><div id=noncoding_gc class="link" onclick = "gen_data(['args__loading...'],['noncoding_gc']);\$('#noncoding_gc').removeClass('link');  get_gc_for_noncoding(['args__dsid','ds_id','args__chr','chr','args__gstid', 'gstid'],['noncoding_gc']);">Click for percent GC content</div>
} if $length;

    my $feat_string = qq{
<tr><td><div class=small id=feature_count onclick="gen_data(['args__loading...'],['chr_features']);get_feature_counts(['args__dsid','ds_id','args__chr','chr','args__gstid', 'gstid'],['chr_features']);" >Click for Features</div></td></tr>};

    $html .= $feat_string;
    $html .= "</table></td>";
    $html .= qq{<td id=chr_features></td>};
    $html .= qq{</table>};
    my $viewer;
    if (defined $chr)
     {
	$viewer .= "<font>Genome Viewer</font><br>";
	$viewer .= "<table class=\"small ui-corner-all ui-widget-content\">";
	$viewer .= "<tr><td nowrap>Starting location: ";
	$viewer .= qq{<td><input type="text" size=10 value="20000" id="x">};
	$viewer .= qq{<tr><td >Zoom level:<td><input type = "text" size=10 value ="6" id = "z">};
	$viewer .= qq{<tr><td colspan=2><span style="font-size:1em" class='ui-button ui-button-icon-left ui-corner-all' onClick="launch_viewer('$dsgid', '$chr')"><span class="ui-icon ui-icon-newwin"></span>Launch Genome Viewer</span>};
	$viewer .= "</table>";

      }
    my $seq_grab;
    if (defined $chr)
      {
	$seq_grab .= qq{<font>Genomic Sequence Retrieval</font><br>};
	$seq_grab .= qq{<table class=\"small ui-corner-all ui-widget-content\">};
	$seq_grab .= "<tr><td>Start position: ";
	$seq_grab .= qq{<td><input type="text" size=10 value="1" id="start">};
	$seq_grab .= "<tr><td>End position: ";
	$seq_grab .= qq{<td><input type="text" size=10 value="100000" id="stop">};
	$seq_grab .= qq{<tr><td colspan=2><span style="font-size:1em" class='ui-button ui-button-icon-left ui-corner-all' onClick="launch_seqview('$dsgid', '$chr','$dsid')"><span class="ui-icon ui-icon-newwin"></span>Get Sequence</span>};
	$seq_grab .= qq{</table>};

      }
    return $html, $viewer, $seq_grab;
  }

sub get_feature_counts
  {
    my %opts = @_;
    my $dsid = $opts{dsid};
    my $dsgid = $opts{dsgid};
    my $gstid=$opts{gstid};
    my $chr = $opts{chr};
    my $query;
    my $name;
    if ($dsid)
      {
	my $ds = $coge->resultset('Dataset')->find($dsid);
	$name = "dataset ". $ds->name;
	$query = qq{
SELECT count(distinct(feature_id)), ft.name, ft.feature_type_id
  FROM feature
  JOIN feature_type ft using (feature_type_id)
 WHERE dataset_id = $dsid
};
	$query .= qq{AND chromosome = '$chr'} if defined $chr;
	$query.= qq{
  GROUP BY ft.name
};
	$name .= " chromosome $chr" if defined $chr;
      }
    elsif ($dsgid)
      {
	my $dsg = $coge->resultset('DatasetGroup')->find($dsgid);
	$name = "dataset group ";
	$name .= $dsg->name ? $dsg->name : $dsg->organism->name;
	$query = qq{
SELECT count(distinct(feature_id)), ft.name, ft.feature_type_id
  FROM feature
  JOIN feature_type ft using (feature_type_id)
  JOIN dataset_connector dc using (dataset_id)
 WHERE dataset_group_id = $dsgid
  GROUP BY ft.name

};
      }

    my $dbh = DBI->connect($connstr,$DBUSER,$DBPASS);
    my $sth = $dbh->prepare($query);
    $sth->execute;
    my $feats = {};
    while (my $row = $sth->fetchrow_arrayref)
      {
	my $name = $row->[1];
	$name =~ s/\s+/_/g;
	$feats->{$name} = {count=>$row->[0],
			   id=>$row->[2],
			   name=>$row->[1],
			  };
      }
    my $gc_args;
    $gc_args = "chr: '$chr'," if defined $chr;
    $gc_args .= "dsid: $dsid," if $dsid; #set a var so that histograms are only calculated for the dataset and not hte dataset_group
    $gc_args .= "typeid: ";
    my $feat_list_string = $dsid ? "dsid=$dsid" : "dsgid=$dsgid";
    $feat_list_string .= ";chr=$chr" if defined $chr;
    my $feat_string;# .= qq{<div>Features for $name</div>};
    $feat_string .= qq{<div class = " ui-corner-all ui-widget-content small">};
    $feat_string .= qq{<table class=small>};
    $feat_string .= "<tr valign=top>". join ("\n<tr valign=top>",map {
      "<td valign=top><div id=$_  >".$feats->{$_}{name}." (ftid".$feats->{$_}{id}.")</div>".
	    "<td valign=top align=right>".commify($feats->{$_}{count}).
	      "<td><div id=".$_."_type class=\"link small\" 
  onclick=\"
  \$('#gc_histogram').dialog('option','title', 'Histogram of GC content for ".$feats->{$_}{name}."s');
  \$('#gc_histogram').dialog('open');".
  "get_feat_gc({$gc_args".$feats->{$_}{id}."})\">"
    .'show %GC?</div>'.


    "<td class='small link' onclick=\"window.open('FeatList.pl?$feat_list_string"."&ftid=".$feats->{$_}{id}.";gstid=$gstid')\">Feature List?"
  } sort {$a cmp $b} keys %$feats);
	$feat_string .= "</table>";
    
    if ($feats->{CDS})
      {
	my $args;
	$args .= "'args__dsid','ds_id'," if $dsid;
	$args .= "'args__dsgid','dsg_id'," if $dsgid;
	$args .= "'args__chr','chr'," if defined $chr;
	$feat_string .= "<div class=\"small link\" id=wobble_gc onclick=\"\$('#wobble_gc_histogram').html('loading...');\$('#wobble_gc_histogram').dialog('open');get_wobble_gc([$args],['wobble_gc_histogram'])\">"."Click for codon wobble GC content"."</div>";
	$feat_string .= "<div class=\"small link\" id=wobble_gc_diff onclick=\"\$('#wobble_gc_diff_histogram').html('loading...');\$('#wobble_gc_diff_histogram').dialog('open');get_wobble_gc_diff([$args],['wobble_gc_diff_histogram'])\">"."Click for diff(CDS GC vs. codon wobble GC) content"."</div>";
	$feat_string .= "<div class=\"small link\" id=codon_usage onclick=\"
        \$('#codon_usage_table').html('loading...');
        \$('#codon_usage_table').dialog('open');
        get_codon_usage([$args],['codon_usage_table']); 
        \">".
        "Click for codon usage table"."</div>";
	$feat_string .= "<div class=\"small link\" id=aa_usage onclick=\"
        \$('#aa_usage_table').html('loading...');
        \$('#aa_usage_table').dialog('open');
        get_aa_usage([$args],[open_aa_usage_table]); 
        \">".
        "Click for amino acid usage table"."</div>";

      }
    $feat_string .="</div>";
    $feat_string .= "None" unless keys %$feats;
    return $feat_string;
  }

sub gen_data
  {
    my $message = shift;
    return qq{<font class="small alert">$message</font>};
  }

sub get_gc_for_feature_type
  {
    my %opts = @_;
    my $dsid = $opts{dsid};
    my $dsgid = $opts{dsgid};
    my $chr = $opts{chr};
    my $typeid = $opts{typeid};
    my $gstid = $opts{gstid};#genomic sequence type id
    my $min = $opts{min}; #limit results with gc values greater than $min;
    my $max = $opts{max}; #limit results with gc values smaller than $max;
    my $hist_type = $opts{hist_type};
    $hist_type = "counts" unless $hist_type;
    $min = undef if $min && $min eq "undefined";
    $max = undef if $max && $max eq "undefined";
    $chr = undef if $chr && $chr eq "undefined";
    $dsid = undef if $dsid && $dsid eq "undefined";
    $hist_type = undef if $hist_type && $hist_type eq "undefined";
    $typeid = 1 if $typeid eq "undefined";
    return unless $dsid || $dsgid;
    my $gc = 0;
    my $at = 0;
    my $n = 0;
    my $type = $coge->resultset('FeatureType')->find($typeid);
    my @data;
    my @fids; #storage for fids that passed.  To be sent to FeatList
    my @dsids;
    push @dsids, $1 if $dsid && $dsid =~ /(\d+)/;
    if ($dsgid)
      {
	my $dsg = $coge->resultset('DatasetGroup')->find($dsgid);
	unless ($dsg)
	  {
	    my $error =  "unable to create dsg object using id $dsgid\n";
	    return $error;
	  }
	$gstid = $dsg->type->id;
	if (!$dsid)
	  {
	    foreach my $ds ($dsg->datasets())
	      {
		push @dsids, $ds->id;
	      }
	  }
      }
    my $search;
    $search = {"feature_type_id"=>$typeid};
    $search->{"me.chromosome"}=$chr if defined $chr;
    foreach my $dsidt (@dsids)
      {
	my $ds = $coge->resultset('Dataset')->find($dsidt);
	unless ($ds)
	  {
	    warn "no dataset object found for id $dsidt\n";
	    next;
	  }
	my $t1 = new Benchmark;
	my %seqs; #let's prefetch the sequences with one call to genomic_sequence (slow for many seqs)
	if (defined $chr)
	  {
	    $seqs{$chr} = $ds->genomic_sequence(chr=>$chr, seq_type=>$gstid);
	  }
	else
	  {
	    %seqs= map {$_, $ds->genomic_sequence(chr=>$_, seq_type=>$gstid)} $ds->chromosomes;
	  }
	my $t2 = new Benchmark;
	my @feats = $ds->features($search,{join=>['locations', {'dataset'=>{'dataset_connectors'=>'dataset_group'}}],
					   prefetch=>['locations',{'dataset'=>{'dataset_connectors'=>'dataset_group'}}],
					  });
 	foreach my $feat (@feats)
 	  {
	    my $seq = substr($seqs{$feat->chromosome}, $feat->start-1, $feat->stop-$feat->start+1);

	    $feat->genomic_sequence(seq=>$seq);
	    my @gc = $feat->gc_content(counts=>1);
	    
	    $gc+=$gc[0] if $gc[0] =~ /^\d+$/;
	    $at+=$gc[1] if $gc[1] =~ /^\d+$/;
	    $n+=$gc[2] if $gc[2] =~ /^\d+$/;
	    my $total = 0;
	    $total += $gc[0] if $gc[0];
	    $total += $gc[1] if $gc[1];
	    $total += $gc[2] if $gc[2];
	    my $perc_gc = 100*$gc[0]/$total if $total;
	    next unless $perc_gc; #skip if no values
	    next if defined $min && $min =~/\d+/ && $perc_gc < $min; #check for limits
	    next if defined $max && $max =~/\d+/ && $perc_gc > $max; #check for limits
	    push @data, sprintf("%.2f",$perc_gc);
	    push @fids, $feat->id."_".$gstid;
	  }
	my $t3 = new Benchmark;
	my $get_seq_time = timestr(timediff($t2,$t1));
	my $process_seq_time = timestr(timediff($t3,$t2));
       }
    my $total = $gc+$at+$n;
    return "error" unless $total;

    my $file = $TEMPDIR."/".join ("_",@dsids);
    #perl -T flag
    ($min) = $min =~ /(.*)/ if defined $min;
    ($max) = $max =~ /(.*)/ if defined $max;
    ($chr) = $chr =~ /(.*)/ if defined $chr;
    $file .= "_".$chr."_" if defined $chr;
    $file .= "_min".$min if defined $min;
    $file .= "_max".$max if defined $max;
    $file .= "_$hist_type" if $hist_type;
    $file .= "_".$type->name."_gc.txt";
    open(OUT, ">".$file);
    print OUT "#wobble gc for dataset ids: ".join (" ", @dsids),"\n";
    print OUT join ("\n", @data),"\n";
    close OUT;
    my $cmd = $HISTOGRAM;
    $cmd .= " -f $file";
    my $out = $file;
    $out =~ s/txt$/png/;
    $cmd .= " -o $out";
    $cmd .= " -t \"".$type->name." gc content\"";
    $cmd .= " -min 0";
    $cmd .= " -max 100";
    $cmd .= " -ht $hist_type" if $hist_type;
    `$cmd`;


    $min = 0 unless defined $min && $min =~/\d+/;
    $max = 100 unless defined $max && $max =~/\d+/;
    my $info;
$info .= qq{<div class="small">
Min: <input type="text" size="3" id="feat_gc_min" value="$min">
Max: <input type=text size=3 id=feat_gc_max value=$max>
Type: <select id=feat_hist_type>
<option value ="counts">Counts</option>
<option value = "percentage">Percentage</option>
</select>
};
    $info =~ s/>Per/ selected>Per/ if $hist_type =~/per/;
    my $gc_args;
    $gc_args = "chr: '$chr'," if defined $chr;
    $gc_args .= "dsid: $dsid," if $dsid; #set a var so that histograms are only calculated for the dataset and not hte dataset_group
    $gc_args .= "typeid: '$typeid'";
    $info .= qq{<span class="link" onclick="get_feat_gc({$gc_args})">Regenerate histogram</span>};
    $info .= "</div>";
    $info .= "<div class = small>Total length: ".commify($total)." bp, GC: ".sprintf("%.2f",100*$gc/($total))."%  AT: ".sprintf("%.2f",100*$at/($total))."%  N: ".sprintf("%.2f",100*($n)/($total))."%</div>";
    if ($min || $max)
      {
	$min = 0 unless defined $min;
	$max = 100 unless defined $max;
	$info .= qq{<div class=small style="color: red;">Limits set:  MIN: $min  MAX: $max</div>
} 
      }
    my $stuff = join "::",@fids;
    $info .= qq{<div class="link small" onclick="window.open('FeatList.pl?fid=$stuff')">Open FeatList of Features</div>};
    
    $out =~ s/$TEMPDIR/$TEMPURL/;
    $info .= "<br><img src=\"$out\">";
    return $info;
  }



sub get_gc_for_chromosome
  {
    my %opts = @_;
    my $dsid = $opts{dsid};
    my $chr = $opts{chr};
    my $gstid = $opts{gstid};
    my $dsgid = $opts{dsgid};
    my @ds;
    if ($dsid)
      {
	my $ds = $coge->resultset('Dataset')->find($dsid);
	push @ds, $ds if $ds;
      }
    if ($dsgid)
      {
	my $dsg = $coge->resultset('DatasetGroup')->find($dsgid);
	$gstid = $dsg->type->id;
	map {push @ds,$_} $dsg->datasets;
      }
    return unless @ds;
    my ($gc, $at, $n, $x) = (0,0,0,0);
    my %chr;
    foreach my $ds (@ds)
      {
	if (defined $chr)
	  {
	    $chr{$chr}=1;
	  }
	else
	  {
	    map {$chr{$_}=1} $ds->chromosomes;
	  }
	foreach my $chr(keys %chr)
	  {
	    my @gc =$ds->percent_gc(chr=>$chr, seq_type=>$gstid, count=>1);
	    $gc+= $gc[0] if $gc[0];
	    $at+= $gc[1] if $gc[1];
	    $n+= $gc[2] if $gc[2];
	    $x+= $gc[3] if $gc[3];
	  }
      }
    my $total = $gc+$at+$n+$x;
    return "error" unless $total;
    my $results = "&nbsp(GC: ".sprintf("%.2f",100*$gc/$total)."%  AT: ".sprintf("%.2f",100*$at/$total)."%  N: ".sprintf("%.2f",100*$n/$total)."%  X: ".sprintf("%.2f",100*$x/$total)."%)" if $total;
    return $results;
  }

sub get_gc_for_noncoding
  {
    my %opts = @_;
    my $dsid = $opts{dsid};
    my $dsgid = $opts{dsgid};
    my $chr = $opts{chr};
    my $gstid = $opts{gstid}; #genomic sequence type id
    return "error" unless $dsid || $dsgid;
    my $gc = 0;
    my $at = 0;
    my $n = 0;
    my $x = 0;
    my $search;
    $search = {"feature_type_id"=>3};
    $search->{"me.chromosome"}=$chr if defined $chr;
    my @data;
    my @dsids;
    push @dsids, $dsid if $dsid;
    if ($dsgid)
      {
	my $dsg = $coge->resultset('DatasetGroup')->find($dsgid);
	unless ($dsg)
	  {
	    my $error =  "unable to create dsg object using id $dsgid\n";
	    return $error;
	  }
	$gstid = $dsg->type->id;
	foreach my $ds ($dsg->datasets())
	  {
	    push @dsids, $ds->id;
	  }
      }
    my %seqs; #let's prefetch the sequences with one call to genomic_sequence (slow for many seqs)
    foreach my $dsidt (@dsids)
      {
	my $ds = $coge->resultset('Dataset')->find($dsidt);
	unless ($ds)
	  {
	    warn "no dataset object found for id $dsidt\n";
	    next;
	  }
	
	if (defined $chr)
	  {
	    $seqs{$chr} = $ds->genomic_sequence(chr=>$chr, seq_type=>$gstid);
	  }
	else
	  {
	    map {$seqs{$_}= $ds->genomic_sequence(chr=>$_, seq_type=>$gstid)} $ds->chromosomes;
	  }
	foreach my $feat ($ds->features($search,{join=>['locations', {'dataset'=>{'dataset_connectors'=>'dataset_group'}}],
						 prefetch=>['locations',{'dataset'=>{'dataset_connectors'=>'dataset_group'}}]}))
	  {
	    foreach my $loc ($feat->locations)
	      {
		if ($loc->stop > length ($seqs{$feat->chromosome}))
		  {
		    print STDERR "feature ".$feat->id ." stop exceeds sequence length: ".$loc->stop." :: ".length($seqs{$feat->chromosome}),"\n";
		  }
		substr($seqs{$feat->chromosome}, $loc->start-1,($loc->stop-$loc->start+1)) = "-"x($loc->stop-$loc->start+1);
	      }
#	    push @data, sprintf("%.2f",100*$gc[0]/$total) if $total;
	  }
      }
    foreach my $seq (values %seqs)
      {
	$gc += $seq=~tr/GCgc/GCgc/;
	$at += $seq=~tr/ATat/ATat/;
	$n += $seq =~ tr/nN/nN/;
	$x += $seq =~ tr/xX/xX/;
      }
    my $total = $gc+$at+$n+$x;
    return "error" unless $total;
    return commify($total)." bp"."&nbsp(GC: ".sprintf("%.2f",100*$gc/($total))."%  AT: ".sprintf("%.2f",100*$at/($total))."% N: ".sprintf("%.2f",100*$n/($total))."% X: ".sprintf("%.2f",100*$x/($total))."%)";





    my $file = $TEMPDIR."/".join ("_",@dsids)."_wobble_gc.txt";
    open(OUT, ">".$file);
    print OUT "#wobble gc for dataset ids: ".join (" ", @dsids),"\n";
    print OUT join ("\n", @data),"\n";
    close OUT;
    my $cmd = $HISTOGRAM;
    $cmd .= " -f $file";
    my $out = $file;
    $out =~ s/txt$/png/;
    $cmd .= " -o $out";
    $cmd .= " -t \"CDS wobble gc content\"";
    $cmd .= " -min 0";
    $cmd .= " -max 100";
    `$cmd`;
    my $info =  "<div class = small>Total: ".commify($total)." codons.  Mean GC: ".sprintf("%.2f",100*$gc/($total))."%  AT: ".sprintf("%.2f",100*$at/($total))."%  N: ".sprintf("%.2f",100*($n)/($total))."%</div>";
    $out =~ s/$TEMPDIR/$TEMPURL/;
    my $hist_img = "<img src=\"$out\">";

    return $info, $hist_img;
  }

sub get_codon_usage
  {
    my %opts = @_;
    my $dsid = $opts{dsid};
    my $chr = $opts{chr};
    my $dsgid = $opts{dsgid};
    my $gstid = $opts{gstid};
    return unless $dsid || $dsgid;

    my $search;
    $search = {"feature_type.name"=>"CDS"};
    $search->{"me.chromosome"}=$chr if defined $chr;

    my @dsids;
    push @dsids, $dsid if $dsid;
    if ($dsgid)
      {
	my $dsg = $coge->resultset('DatasetGroup')->find($dsgid);
	unless ($dsg)
	  {
	    my $error =  "unable to create dsg object using id $dsgid\n";
	    return $error;
	  }
	$gstid = $dsg->type->id;
	foreach my $ds ($dsg->datasets())
	  {
	    push @dsids, $ds->id;
	  }
      }
    my %codons;
    my $codon_total = 0;
    my $feat_count = 0;
    my ($code, $code_type);

    foreach my $dsidt (@dsids)
      {
	my $ds = $coge->resultset('Dataset')->find($dsidt);
	my %seqs; #let's prefetch the sequences with one call to genomic_sequence (slow for many seqs)
	if (defined $chr)
	  {
	    $seqs{$chr} = $ds->genomic_sequence(chr=>$chr, seq_type=>$gstid);
	  }
	else
	  {
	    %seqs= map {$_, $ds->genomic_sequence(chr=>$_, seq_type=>$gstid)} $ds->chromosomes;
	  }
	foreach my $feat ($ds->features($search,{join=>["feature_type",'locations', {'dataset'=>{'dataset_connectors'=>'dataset_group'}}],
						 prefetch=>['locations',{'dataset'=>{'dataset_connectors'=>'dataset_group'}}]}))
	  {
	    my $seq = substr($seqs{$feat->chromosome}, $feat->start-1, $feat->stop-$feat->start+1);
	    $feat->genomic_sequence(seq=>$seq);
	    $feat_count++;
	    ($code, $code_type) = $feat->genetic_code() unless $code;
	    my ($codon) = $feat->codon_frequency(counts=>1);
	    grep {$codon_total+=$_} values %$codon;
	    grep {$codons{$_}+=$codon->{$_}} keys %$codon;
	    print STDERR ".($feat_count)" if !$feat_count%10;
	  }
      }
    %codons = map {$_,$codons{$_}/$codon_total} keys %codons;

    #Josh put some stuff in here so he could get raw numbers instead of percentages for aa usage. He should either make this an option or delete this code when he is done. REMIND HIM ABOUT THIS IF YOU ARE EDITING ORGVIEW!
    my $html = "Codon Usage: $code_type";
    $html .= CoGe::Accessory::genetic_code->html_code_table(data=>\%codons, code=>$code);
    return $html
  }

sub get_aa_usage
  {
    my %opts = @_;
    my $dsid = $opts{dsid};
    my $chr = $opts{chr};
    my $dsgid = $opts{dsgid};
    my $gstid = $opts{gstid};
    return unless $dsid || $dsgid;

    my $search;
    $search = {"feature_type.name"=>"CDS"};
    $search->{"me.chromosome"}=$chr if defined $chr;

    my @dsids;
    push @dsids, $dsid if $dsid;
    if ($dsgid)
      {
	my $dsg = $coge->resultset('DatasetGroup')->find($dsgid);
	unless ($dsg)
	  {
	    my $error =  "unable to create dsg object using id $dsgid\n";
	    return $error;
	  }
	$gstid = $dsg->type->id;
	foreach my $ds ($dsg->datasets())
	  {
	    push @dsids, $ds->id;
	  }
      }
    my %codons;
    my $codon_total = 0;
    my %aa;
    my $aa_total=0;
    my $feat_count = 0;
    my ($code, $code_type);

    foreach my $dsidt (@dsids)
      {
	my $ds = $coge->resultset('Dataset')->find($dsidt);
	my %seqs; #let's prefetch the sequences with one call to genomic_sequence (slow for many seqs)
	if (defined $chr)
	  {
	    $seqs{$chr} = $ds->genomic_sequence(chr=>$chr, seq_type=>$gstid);
	  }
	else
	  {
	    %seqs= map {$_, $ds->genomic_sequence(chr=>$_, seq_type=>$gstid)} $ds->chromosomes;
	  }
	foreach my $feat ($ds->features($search,{join=>["feature_type",'locations', {'dataset'=>{'dataset_connectors'=>'dataset_group'}}],
						 prefetch=>['locations',{'dataset'=>{'dataset_connectors'=>'dataset_group'}}]}))
	  {
	    my $seq = substr($seqs{$feat->chromosome}, $feat->start-1, $feat->stop-$feat->start+1);
	    $feat->genomic_sequence(seq=>$seq);
	    $feat_count++;
	    ($code, $code_type) = $feat->genetic_code() unless $code;
	    my ($codon) = $feat->codon_frequency(counts=>1);
	    grep {$codon_total+=$_} values %$codon;
	    grep {$codons{$_}+=$codon->{$_}} keys %$codon;
	    foreach my $tri (keys %$code)
	      {
		$aa{$code->{$tri}}+=$codon->{$tri};
		$aa_total+=$codon->{$tri};
	      }
	    print STDERR ".($feat_count)" if !$feat_count%10;
	  }
      }
    %codons = map {$_,$codons{$_}/$codon_total} keys %codons;

    #Josh put some stuff in here so he could get raw numbers instead of percentages for aa usage. He should either make this an option or delete this code when he is done. REMIND HIM ABOUT THIS IF YOU ARE EDITING ORGVIEW!
    %aa = $USER->user_name =~ /jkane/i ? map {$_,$aa{$_}} keys %aa : map {$_,$aa{$_}/$aa_total} keys %aa;
    
#    my $html1 = "Codon Usage: $code_type";
#    $html1 .= CoGe::Accessory::genetic_code->html_code_table(data=>\%codons, code=>$code);
    
    my $html2 .= "Predicted amino acid usage using $code_type";
    $html2 .= "<br/>Total Amino Acids: $aa_total" if $USER->user_name =~ /jkane/i;
    $html2 .= CoGe::Accessory::genetic_code->html_aa_new(data=>\%aa);
    $html2 =~ s/00.00%//g if $USER->user_name =~ /jkane/i;
    return $html2;
#    return $html1, $html2;
  }

sub get_wobble_gc
  {
    my %opts = @_;
    my $dsid = $opts{dsid};
    my $dsgid = $opts{dsgid};
    my $chr = $opts{chr};
    my $gstid = $opts{gstid}; #genomic sequence type id
    my $min = $opts{min}; #limit results with gc values greater than $min;
    my $max = $opts{max}; #limit results with gc values smaller than $max;
    my $hist_type = $opts{hist_type};
    return "error" unless $dsid || $dsgid;
    my $gc = 0;
    my $at = 0;
    my $n = 0;
    my $search;
    $search = {"feature_type_id"=>3};
    $search->{"me.chromosome"}=$chr if defined $chr;
    my @data;
    my @fids;
    my @dsids;
    push @dsids, $dsid if $dsid;
    if ($dsgid)
      {
	my $dsg = $coge->resultset('DatasetGroup')->find($dsgid);
	unless ($dsg)
	  {
	    my $error =  "unable to create dsg object using id $dsgid\n";
	    return $error;
	  }
	$gstid = $dsg->type->id;
	foreach my $ds ($dsg->datasets())
	  {
	    push @dsids, $ds->id;
	  }
      }
    foreach my $dsidt (@dsids)
      {
	my $ds = $coge->resultset('Dataset')->find($dsidt);
	unless ($ds)
	  {
	    warn "no dataset object found for id $dsidt\n";
	    next;
	  }
	foreach my $feat ($ds->features($search,{join=>['locations', {'dataset'=>{'dataset_connectors'=>'dataset_group'}}],
						 prefetch=>['locations',{'dataset'=>{'dataset_connectors'=>'dataset_group'}}],
						}))
	  {
	    my @gc = $feat->wobble_content(counts=>1);
	    $gc+=$gc[0] if $gc[0] && $gc[0] =~ /^\d+$/;
	    $at+=$gc[1] if $gc[1] && $gc[1] =~ /^\d+$/;
	    $n+=$gc[2] if $gc[2] && $gc[2] =~ /^\d+$/;
	    my $total = 0;
	    $total += $gc[0] if $gc[0];
	    $total += $gc[1] if $gc[1];
	    $total += $gc[2] if $gc[2];
	    my $perc_gc = 100*$gc[0]/$total if $total;
	    next unless $perc_gc; #skip if no values
	    next if defined $min && $min =~/\d+/ && $perc_gc < $min; #check for limits
	    next if defined $max && $max =~/\d+/ && $perc_gc > $max; #check for limits
	    push @data, sprintf("%.2f",$perc_gc);
	    push @fids, $feat->id."_".$gstid;
	    #push @data, sprintf("%.2f",100*$gc[0]/$total) if $total;
	  }
      }
    my $total = $gc+$at+$n;
    return "error" unless $total;
    
    my $file = $TEMPDIR."/".join ("_",@dsids);#."_wobble_gc.txt";
    ($min) = $min =~ /(.*)/ if defined $min;
    ($max) = $max =~ /(.*)/ if defined $max;
    ($chr) = $chr =~ /(.*)/ if defined $chr;
    $file .= "_".$chr."_" if defined $chr;
    $file .= "_min".$min if defined $min;
    $file .= "_max".$max if defined $max;
    $file .= "_$hist_type" if $hist_type;
    $file .= "_wobble_gc.txt";
    open(OUT, ">".$file);
    print OUT "#wobble gc for dataset ids: ".join (" ", @dsids),"\n";
    print OUT join ("\n", @data),"\n";
    close OUT;
    my $cmd = $HISTOGRAM;
    $cmd .= " -f $file";
    my $out = $file;
    $out =~ s/txt$/png/;
    $cmd .= " -o $out";
    $cmd .= " -t \"CDS wobble gc content\"";
    $cmd .= " -min 0";
    $cmd .= " -max 100";
    $cmd .= " -ht $hist_type" if $hist_type;
     `$cmd`;
    $min = 0 unless defined $min && $min =~/\d+/;
    $max = 100 unless defined $max && $max =~/\d+/;
    my $info;
    $info .= qq{<div class="small">
Min: <input type="text" size="3" id="wobble_gc_min" value="$min">
Max: <input type=text size=3 id=wobble_gc_max value=$max>
Type: <select id=wobble_hist_type>
<option value ="counts">Counts</option>
<option value = "percentage">Percentage</option>
</select>
};
    $info =~ s/>Per/ selected>Per/ if $hist_type =~/per/;
    my $args;
    $args .= "'args__dsid','ds_id'," if $dsid;
    $args .= "'args__dsgid','dsg_id'," if $dsgid;
    $args .= "'args__chr','chr'," if defined $chr;
    $args .= "'args__min','wobble_gc_min',";
    $args .= "'args__max','wobble_gc_max',";
    $args .= "'args__max','wobble_gc_max',";
    $args .= "'args__hist_type', 'wobble_hist_type',";
    $info .= qq{<span class="link" onclick="get_wobble_gc([$args],['wobble_gc_histogram']);\$('#wobble_gc_histogram').html('loading...');">Regenerate histogram</span>};
    $info .= "</div>";

    $info .=  "<div class = small>Total: ".commify($total)." codons.  Mean GC: ".sprintf("%.2f",100*$gc/($total))."%  AT: ".sprintf("%.2f",100*$at/($total))."%  N: ".sprintf("%.2f",100*($n)/($total))."%</div>";
    if ($min || $max)
      {
	$min = 0 unless defined $min;
	$max = 100 unless defined $max;
	$info .= qq{<div class=small style="color: red;">Limits set:  MIN: $min  MAX: $max</div>
} 
  }
    my $stuff = join "::",@fids;
    $info .= qq{<div class="link small" onclick="window.open('FeatList.pl?fid=$stuff')">Open FeatList of Features</div>};
    $out =~ s/$TEMPDIR/$TEMPURL/;
    my $hist_img = "<img src=\"$out\">";
    return $info."<br>". $hist_img;
  }

sub get_wobble_gc_diff
  {
    my %opts = @_;
    my $dsid = $opts{dsid};
    my $dsgid = $opts{dsgid};
    my $chr = $opts{chr};
    my $gstid = $opts{gstid}; #genomic sequence type id
    return "error"," " unless $dsid || $dsgid;
    my $search;
    $search = {"feature_type_id"=>3};
    $search->{"me.chromosome"}=$chr if defined $chr;
    my @data;
    my @dsids;
    push @dsids, $dsid if $dsid;
    if ($dsgid)
      {
	my $dsg = $coge->resultset('DatasetGroup')->find($dsgid);
	unless ($dsg)
	  {
	    my $error =  "unable to create dsg object using id $dsgid\n";
	    return $error;
	  }
	$gstid = $dsg->type->id;
	foreach my $ds ($dsg->datasets())
	  {
	    push @dsids, $ds->id;
	  }
      }
    foreach my $dsidt (@dsids)
      {
	my $ds = $coge->resultset('Dataset')->find($dsidt);
	unless ($ds)
	  {
	    warn "no dataset object found for id $dsidt\n";
	    next;
	  }
	foreach my $feat ($ds->features($search,{join=>['locations', {'dataset'=>{'dataset_connectors'=>'dataset_group'}}],
						 prefetch=>['locations',{'dataset'=>{'dataset_connectors'=>'dataset_group'}}]}
				       ))
	  {
	    my @wgc = $feat->wobble_content();
	    my @gc = $feat->gc_content();
	    my $diff = $gc[0]-$wgc[0] if defined $gc[0] && defined $wgc[0];
	    push @data, sprintf("%.2f", 100*$diff) if $diff;
	  }
      }
    return "error"," " unless @data;
    my $file = $TEMPDIR."/".join ("_",@dsids)."_wobble_gc_diff.txt";
    open(OUT, ">".$file);
    print OUT "#wobble gc for dataset ids: ".join (" ", @dsids),"\n";
    print OUT join ("\n", @data),"\n";
    close OUT;
    my $cmd = $HISTOGRAM;
    $cmd .= " -f $file";
    my $out = $file;
    $out =~ s/txt$/png/;
    $cmd .= " -o $out";
    $cmd .= " -t \"CDS GC - wobble gc content\"";
    `$cmd`;
    my $sum=0;
    map {$sum+=$_}@data;
    my $mean = sprintf ("%.2f", $sum/scalar @data);
    my $info = "Mean $mean%";
    $info .= " (";
    $info .= $mean > 0 ? "CDS" : "wobble";
    $info .= " is more GC rich)";
    $out =~ s/$TEMPDIR/$TEMPURL/;
    my $hist_img = "<img src=\"$out\">";
    return $info."<br>". $hist_img;
  }

sub get_total_length_for_ds
  {
    my %opts = @_;
    my $dsid = $opts{dsid};
    my $ds = $coge->resultset('Dataset')->find($dsid);
    my $length = 0;
    map {$length+=$ds->last_chromosome_position($_)} $ds->get_chromosomes();
    return commify($length);
  }

sub commify
    {
      my $text = reverse $_[0];
      $text =~ s/(\d\d\d)(?=\d)(?!\d*\.)/$1,/g;
      return scalar reverse $text;
    }

1;
