### Tools::Check test suite ###

use strict;
use lib '../lib';
use Test::More tests => 12;

### case 1 ###
use_ok( 'Archive::Tar' ) or diag "Archive/Tar.pm not found.  Dying", die;

my $flag;
eval 'use Compress::Zlib'
    or $flag++ && diag "Compress::Zlib not available: will not do compression tests";

{
    my $tar = Archive::Tar->new;
    ok( $tar,                       q[Create object for writing] );
    ok( $tar->add_files($0),        q[Add files] );
    ok( $tar->add_data('a','foo'),  q[Adding data] );
    ok( $tar->write('out.tar'),     q[Write, uncompressed] );

    SKIP: {
        skip( "Can not do compression checks", 1 ) if $flag;
        ok( $tar->write('out.tgz', 1),  q[Write, compressed] );
    }
}

{

    my $tar = Archive::Tar->new($flag ? ('out.tar') : ('out.tgz',1));
    ok( $tar,                               q[Create object for reading] );
    ok( $tar->get_content('a') eq 'foo',   q[Reading file content] );
    ok( !$tar->read('/exists/not'),         q[Testing integrity] );

    TODO: {
        local $TODO = 'Evil stringification issues with $!';
        ok( $tar->error ? 1 : 0,            q[Error spotted] );
    }

    ok( $tar->set_error('new'),             q[Setting error] );
    ok( $tar->error eq 'new',               q[Error set] );
}

unlink 'out.tar', 'out.tgz';
