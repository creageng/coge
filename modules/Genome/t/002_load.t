# -*- perl -*-

# t/002_load.t - check module loading and create testing directory

use Test::More tests => 2;

BEGIN { use_ok( 'CoGe::Genome::DB::Annotation' ); }

my $object = CoGe::Genome::DB::Annotation->new ();
isa_ok ($object, 'CoGe::Genome::DB::Annotation');


