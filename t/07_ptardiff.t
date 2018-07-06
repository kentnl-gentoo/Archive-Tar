use strict;
use warnings;

BEGIN {
  unless ( $ENV{GENTOO_TAR_PTARDIFF} ) {
    print "1..0 # SKIP this test requires GENTOO_TAR_PTARDIFF set";
    exit
  }
}

use Test::More;

use File::Spec;
use FindBin '$Bin';
use Archive::Tar;

# filenames
my $tartest = File::Spec->catfile("t", "ptardiff");
my $foo = File::Spec->catfile("t", "ptardiff", "foo");
my $bar = File::Spec->catfile("t", "ptardiff", "bar");
my $tarfile = File::Spec->catfile("t", "ptardiff.tar");
my $ptardiff = File::Spec->catfile($Bin, "..", "bin", "ptardiff");
my $cmd = "$^X $ptardiff $tarfile";

require Text::Diff;
plan tests => 1;

# create directory/files
mkdir $tartest;
open my $fh, ">", $foo or die $!;
print $fh "file foo\n";
close $fh;
open $fh, ">", $bar or die $!;
print $fh "file bar\n";
close $fh;

# create archive
my $tar = Archive::Tar->new;
$tar->add_files($foo, $bar);
$tar->write($tarfile);

# change file
open $fh, ">>", $foo or die $!;
print $fh "added\n";
close $fh;

# see if ptardiff shows the changes
my $out = qx{$cmd};
cmp_ok($out, '=~', qr{^\+added$}m, "ptardiff shows added text");

# cleanup
END {
    unlink $tarfile;
    if ( -e $foo ) { unlink $foo or die $!; }
    if ( -e $bar ) { unlink $bar or die $!; }
    if ( -d $tartest ) { rmdir $tartest or die $!; }
}
