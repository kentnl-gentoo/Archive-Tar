# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl test.pl'

######################### We start with some black magic to print on failure.

# Change 1..1 below to 1..last_test_to_print .
# (It may become useful if the test is moved to ./t subdirectory.)

BEGIN { $| = 1; print "1..5\n"; }
END {print "not ok 1\n" unless $loaded;}
use Archive::Tar;
$loaded = 1;
print "ok 1\n";

######################### End of black magic.

# Insert your test code below (better if it prints "ok 13"
# (correspondingly "not ok 13") depending on the success of chunk 13
# of the test code):

use IO::File;

my $t1 = Archive::Tar->new ();
my @files = IO::File->new ("MANIFEST")->getlines ();
chomp @files;
my $data1 = join '', IO::File->new ("test.pl")->getlines ();
print $t1->add_files (@files) 
    ? "ok 2\n" : "not ok 2\n";
print $t1->add_data ('x' . $files[$#files], $data1)
    ? "ok 3\n" : "not ok 3\n";
print $t1->write ("dummy.tar") 
    ? "ok 4\n" : "not ok 3\n";
undef $t1;

package TEST;

@ISA = qw (Archive::Tar);
my $t2 = __PACKAGE__->new ();
$t2->read ("dummy.tar");
my $data2 = $t2->get_content ('x' . $files[$#files]);
print $data1 eq $data2 ? "ok 5\n" : "not ok 5\n";
unlink ("dummy.tar");

1;
