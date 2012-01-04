#! /usr/bin/perl -w

use strict;
use CGI;
use CGI::Ajax;
use CoGe::Accessory::LogUser;
use CoGe::Accessory::Web;
use CoGeX;
use CoGeX::Result::Feature;
use Digest::MD5 qw(md5_base64);
use CoGeX::Result::Dataset;
use HTML::Template;
use Text::Wrap qw($columns &wrap);
use Data::Dumper;
use POSIX;
use DBIxProfiler;
no warnings 'redefine';


use vars qw($P $DBNAME $DBHOST $DBPORT $DBUSER $DBPASS $connstr $TEMPDIR $TEMPURL $FORM $USER $DATE $coge $COOKIE_NAME);

$P = CoGe::Accessory::Web::get_defaults($ENV{HOME}.'coge.conf');
$ENV{PATH} = $P->{COGEDIR};

$TEMPDIR = $P->{TEMPDIR};
$TEMPURL = $P->{TEMPURL};
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

$COOKIE_NAME = $P->{COOKIE_NAME};

my ($cas_ticket) =$FORM->param('ticket');
$USER = undef;
($USER) = CoGe::Accessory::Web->login_cas(ticket=>$cas_ticket, coge=>$coge, this_url=>$FORM->url()) if($cas_ticket);
($USER) = CoGe::Accessory::LogUser->get_user(cookie_name=>$COOKIE_NAME,coge=>$coge) unless $USER;

my $pj = new CGI::Ajax(
		       gen_html=>\&gen_html,
		       get_seq=>\&get_seq,
		       gen_title=>\&gen_title,
		       find_feats=>\&find_feats,
		       parse_url=>\&parse_url,
		       generate_feat_info=>\&generate_feat_info,
		       generate_gc_info=>\&generate_gc_info,
			);
$pj->js_encode_function('escape');
print $pj->build_html($FORM, \&gen_html);
#print $FORM->header, gen_html();

sub gen_html
  {
    my $html;
    unless ($USER)
      {
		$html = login();
      }
    else
     {
    my $form = $FORM;
    my $rc = $form->param('rc');
    my $pro;
    my ($title) = gen_title(protein=>$pro, rc=>$rc);
    my $template = HTML::Template->new(filename=>$P->{TMPLDIR}.'generic_page.tmpl');
#    $template->param(TITLE=>'Sequence Viewer');
    $template->param(PAGE_TITLE=>'SeqView');
    $template->param(HELP=>'/wiki/index.php?title=SeqView');
    my $name = $USER->user_name;
        $name = $USER->first_name if $USER->first_name;
        $name .= " ".$USER->last_name if $USER->first_name && $USER->last_name;
        $template->param(USER=>$name);

    $template->param(DATE=>$DATE);
    $template->param(LOGO_PNG=>"SeqView-logo.png");
    $template->param(BOX_NAME=>qq{<DIV id="box_name">$title</DIV>});
    $template->param(BODY=>gen_body());
    $template->param(ADJUST_BOX=>1);
    $template->param(LOGON=>1) unless $USER->user_name eq "public";
    $html .= $template->output;
    }
    return $html;
  }

sub gen_body
  {
    my $form = $FORM;
    my $featid = $form->param('featid') || $form->param('fid') ||0;
    my $gstid = $form->param('gstid') if $form->param('gstid');
    ($featid, $gstid) = split (/_/, $featid) if ($featid =~ /_/);
      
    my $chr = $form->param('chr');
    my $dsid = $form->param('dsid');
    my $dsgid = $form->param('dsgid');
    my $feat_name = $form->param('featname');
    my $rc = $form->param('rc');
    my $pro = $form->param('pro');   
    my $upstream = $form->param('upstream') || 0;
    my $downstream = $form->param('downstream') || 0;
    my $start = $form->param('start');
    $start =~ s/,//g if $start;
    $start =~ s/\.//g if $start;
    my $stop = $form->param('stop');
    $stop =~ s/,//g if $stop;
    $stop =~ s/\.//g if $stop;
    $stop = $start unless $stop;
    ($start,$stop) = ($stop,$start) if $start && $stop && $start > $stop;
    my $template = HTML::Template->new(filename=>$P->{TMPLDIR}.'SeqView.tmpl');
    $template->param(RC=>$rc);
    $template->param(JS=>1);
    $template->param(SEQ_BOX=>1);
    $template->param(ADDITION=>1);
    $template->param(GSTID=>$gstid);
    $template->param(DSID=>$dsid);
    $template->param(DSGID=>$dsgid);
    $template->param(CHR=>$chr);

    if ($featid)
    {
      my ($feat) = $coge->resultset('Feature')->find($featid);
      $dsid = $feat->dataset_id;
      $chr = $feat->chromosome;

      $template->param(FEAT_START=>$feat->start);
      $template->param(FEAT_STOP=>$feat->stop);
      $template->param(FEATID=>$featid);
      $template->param(FEATNAME=>$feat_name);
#      $template->param(FEAT_INFO=>qq{<span class='ui-button ui-corner-all' onClick="generate_feat_info(['args__$featid'],[display_feat_info]); ">Get Feature Info</span>});
      $template->param(FEAT_INFO=>qq{<span class='ui-button ui-corner-all' onClick="generate_feat_info(['args__$featid'],['feature_info']); \$('#feature_info').dialog('open');">Get Feature Info</span>});
      $template->param(PROTEIN=>'Protein Sequence');
      $template->param(SIXFRAME=>0);
      $template->param(UPSTREAM=>"Add 5': ");
      $template->param(UPVALUE=>$upstream);
      $template->param(DOWNSTREAM=>"Add 3': ");
      $template->param(DOWNVALUE=>$downstream);
      $template->param(FEATURE=>1);
      $start = $feat->start;
      $stop = $feat->stop;
    }
    else
    {
    	$template->param(FEATID=>0); #to make JS happy
    	$template->param(FEATNAME=>'null'); #to make JS happy
        #generate_gc_info(chr=>$chr,stop=>$stop,start=>$start,dsid=>$dsid);

	$template->param(PROTEIN=>'Six Frame Translation');
	$template->param(SIXFRAME=>1);
	$template->param(UPSTREAM=>"Start: ");
	$template->param(UPVALUE=>$start);
	$template->param(DOWNSTREAM=>"Stop: ");
	$template->param(DOWNVALUE=>$stop);
	$template->param(ADD_EXTRA=>1);
	$template->param(ADDUP=>$upstream);
	$template->param(ADDDOWN=>$downstream);


    }
    if ($rc)
      {
	$start -= $downstream;
	$stop += $upstream;
      }
    else
      {
	$start -= $upstream;
	$stop += $downstream;
      }
    my ($link, $types) = find_feats(dsid=>$dsid, start=>$start, stop=>$stop, chr=>$chr, gstid=>$gstid, dsgid=>$dsgid);
#    print STDERR $link,"\n\n";;

    $template->param(FEATLISTLINK=>$link);
    $template->param(FEAT_TYPE_LIST=>$types);
    $template->param(GC_INFO=>qq{<td valign=top><span class='ui-button ui-corner-all'  onClick="generate_gc_info(['seq_text','args__'+myObj.pro],[display_gc_info],'POST')">Calculate GC Content</span>});
    my $html = $template->output;
    return $html;
  }
 

sub check_strand
{
    my %opts = @_;
    my $strand = $opts{'strand'} || 1;
    my $rc = $opts{'rc'} || 0;
    if ($rc==1)
    {
        if ($strand =~ /-/)
          {
            $strand = "1";
          }
        else
          {
            $strand = "-1";
          }
      }
     elsif ($strand =~ /-/)
     {
       $strand =~ s/^\-$/-1/;
     }
     else 
     {
       $strand =~ s/^\+$/1/;
     }
    return $strand;
}

sub get_seq
  {
    my %opts = @_;
    my $add_to_seq = $opts{'add'};
    my $featid = $opts{'featid'} || 0;
    $featid = 0 if $featid eq "undefined"; #javascript funkiness
    my $pro = $opts{'pro'};
    #my $pro = 1;
    my $rc = $opts{'rc'} || 0;
    my $chr = $opts{'chr'};
    my $dsid = $opts{'dsid'};
    my $dsgid = $opts{'dsgid'};
    my $feat_name = $opts{'featname'};
    my $upstream = $opts{'upstream'};
    my $downstream = $opts{'downstream'};
    my $start = $opts{'start'};
    my $stop = $opts{'stop'};
    my $wrap = $opts{'wrap'} || 0;
    my $gstid = $opts{gstid};
    $wrap = 0 if $wrap =~ /undefined/;
    if($add_to_seq){
      $start = $upstream if $upstream;
      $stop = $downstream if $downstream;
    }
    else
      {
	$start-=$upstream;
	$stop+=$downstream;
      }
    my $strand;
    my $seq;
    my $fasta;
    my $col= $wrap ? 80 : 0;

    if ($featid)
      {
	my $feat = $coge->resultset('Feature')->find($featid);
	return "Restricted Access" if $feat->dataset->restricted && !$USER->has_access_to_dataset($feat->dataset);
	($fasta,$seq) = ref($feat) =~ /Feature/i ?
	  $feat->fasta(
		       prot=>$pro,
		       rc=>$rc,
		       upstream=>$upstream,
		       downstream=>$downstream,
		       col=>$col,
		       sep=>1,
		       gstid=>$gstid,
		      )
	    :
	      ">Unable to retrieve Feature object for id: $featid\n";
	
#	$seq = $rc ? color(seq=>$seq, upstream=>$downstream, downstream=>$upstream) : color(seq=>$seq, upstream=>$upstream, downstream=>$downstream);
	$fasta = $fasta."\n".$seq."\n";
      }
    elsif ($dsid)
      {
	my $ds = $coge->resultset('Dataset')->find($dsid);
	return "Restricted Access" if $ds->restricted && !$USER->has_access_to_dataset($ds);
	$fasta = ref ($ds) =~ /dataset/i ? 
	  $ds->fasta
	    (
	     start=>$start,
	     stop=>$stop,
	     chr=>$chr,
	     prot=>$pro,
	     rc=>$rc,
	     col=>$col,
	     gstid=>$gstid,
	    )
	      :
		">Unable to retrieve dataset object for id: $dsid";
      }
    elsif ($dsgid)
      {
	my $dsg = $coge->resultset('DatasetGroup')->find($dsgid);
        return "Restricted Access" if $dsg->restricted && !$USER->has_access_to_genome($dsg);
	$fasta = ref ($dsg) =~ /datasetgroup/i ? 
	  $dsg->fasta
	    (
	     start=>$start,
	     stop=>$stop,
	     chr=>$chr,
	     prot=>$pro,
	     rc=>$rc,
	     col=>$col,
	    )
	      :
		">Unable to retrieve dataset group object for id: $dsgid";
      }
    else
      {
	$fasta = qq{
>Unable to create sequence.  Options:
};
	$fasta.= Dumper \%opts;
      }
    return $fasta;
  }
  
    
sub color
    {
      my %opts = @_;
      my $seq = $opts{'seq'};
#       my $rc = $opts{'rc'};
      my $upstream = $opts{'upstream'};
      my $downstream = $opts{'downstream'};
      $upstream = 0 if $upstream < 0;
      $downstream = 0 if $downstream < 0;
      my $up;
      my $down;
      my $main;
      my $nl1;
      $nl1 = 0;
      $up = substr($seq, 0, $upstream);
      while ($up=~/\n/g)
	{$nl1++;}
      my $check = substr($seq, $upstream, $nl1);
      
      $nl1++ if $check =~ /\n/;
      $upstream += $nl1;
      $up = substr($seq, 0, $upstream);
      my $nl2 = 0;
      $down = substr($seq, ((length $seq)-($downstream)), length $seq);
      while ($down=~/\n/g)
	{$nl2++;}
      $check = substr($seq, ((length $seq)-($downstream+$nl2)), $nl2);
      
      $nl2++ if $check =~ /\n/;
      $downstream += $nl2;
      $down = substr($seq, ((length $seq)-($downstream)), $downstream);
      $up = lc($up);
      $down = lc($down);
      $main = substr($seq, $upstream, (((length $seq)) - ($downstream+$upstream)));
      $main = uc($main);
      $seq = join("", $up, $main, $down);
      return $seq;
    }
    
sub gen_title
    {
      my %opts = @_;
      my $rc = $opts{'rc'} || 0;
      my $pro = $opts{'pro'};
      my $sixframe = $opts{sixframe};
      my $title;
      if ($pro)
      {
        $title = $sixframe ? "Six Frame Translation" : "Protein Sequence";
      }
      else
      {
        $title = $rc ? "Reverse Complement" : "DNA Sequence";
      }
      return $title;
    }
	
sub find_feats
{
	my %opts = @_;
	my $start = $opts{'start'};
	my $stop = $opts{'stop'};
	my $chr = $opts{'chr'};
	my $dsid = $opts{'dsid'};
	my $gstid = $opts{'gstid'};
	my $dsgid = $opts{dsgid};
	if ($dsgid)
	  {
	    my $dsg = $coge->resultset('DatasetGroup')->find($dsgid);
	    return unless $dsg;
	    $dsid = $dsg->datasets(chr=>$chr)->id;
	    $gstid = $dsg->type->id;
	  }
	my $link = qq{<span class='ui-button ui-corner-all' " onClick="featlist('FeatList.pl?};
	my %type;
	$link .="start=$start;stop=$stop;chr=$chr;dsid=$dsid;gstid=$gstid".qq{')">Extract Features: <span>};
	foreach my $ft ($coge->resultset('FeatureType')->search(
								{"features.dataset_id"=>$dsid,
								 "features.chromosome"=>$chr},
								{join=>"features",
								 select=>[{"distinct"=>"me.feature_type_id"},"name"],
								 as=>["feature_type_id","name"],
								}
							   ))
	  {
	    $type{$ft->name}=$ft->id;
	  }
	$type{All}=0;

	my $type = qq{<SELECT ID="feature_type">};
	$type .= join ("\n", map {"<OPTION value=".$type{$_}.">".$_."</option>"} sort keys %type)."\n";
	$type .= "</select>";
        return $link,$type;
}

sub generate_feat_info
  {
    my $featid = shift;
    my ($feat) = $coge->resultset("Feature")->find($featid);
    unless (ref($feat) =~ /Feature/i)
    {
      return "Unable to retrieve Feature object for id: $featid";
    }
#    my $html = qq{<a href="#" onClick="\$('#feature_info').slideToggle(pageObj.speed);" style="float: right;"><img src='/CoGe/picts/delete.png' width='16' height='16' border='0'></a>};
    my $html = $feat->annotation_pretty_print_html();
    return $html;
  }
  
sub generate_gc_info
  {
    my $seq = shift;
    my $seq_type = shift;
    return "Cannot Calculate GC content of Protein Sequence" if $seq_type;
    $seq =~ s/>.*?\n//;
    $seq =~ s/\n//g;
    my $length = length($seq);
    return "No sequence" unless $length;
    my $gc = $seq =~ tr/GCgc/GCgc/;
    my $at = $seq =~ tr/ATat/ATat/;
    my $pgc = sprintf("%.2f",$gc/$length*100);
    my $pat = sprintf("%.2f",$at/$length*100);
    my $total_content = "GC: ".commify($gc)." (".$pgc."%)  AT: ".commify($at)." (".$pat."%)  total length: ".commify($length);
    return $total_content;    
  }

sub commify {
        my $input = shift;
        $input = reverse $input;
        $input =~ s<(\d\d\d)(?=\d)(?!\d*\.)><$1,>g;
        return scalar reverse $input;
}

