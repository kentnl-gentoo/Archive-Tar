#! - perl -
use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile (

    NAME            => 'Archive::Tar',
    VERSION_FROM    => 'lib/Archive/Tar.pm', # finds $VERSION
    EXE_FILES       => ['bin/ptar'],
    dist            => { COMPRESS => 'gzip -9f', SUFFIX => 'gz' },
    PREREQ_PM       => { 'Test::More' => 0 },
    $] >= 5.005
        ? ( 'AUTHOR'    => 'Jos Boumans <kane[at]cpan.org>',
	    'ABSTRACT'  => 'Manipulates TAR archives')
        : ()
); 