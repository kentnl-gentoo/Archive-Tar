use Test::More tests => 53;
use strict;
use File::Spec ();
use Archive::Tar;
use File::Basename ();
    
my $tar = new Archive::Tar;
isa_ok( $tar, 'Archive::Tar', 'Object created' );

my $expect = {
    c   => qr/^iiiiiiiiiiii\s*$/,
    d   => qr/^uuuuuuuu\s*$/,
};

my @root = grep { length } File::Basename::dirname($0), 'src';

my $archive     = File::Spec->catfile( @root, 'bar.tar' );
my $compressed  = File::Spec->catfile( @root, 'foo.tgz' );  
my $zlib    = eval { require IO::Zlib; 1 };

my $gzip = 0;
for my $type( $archive, $compressed ) {    
    
    my $state = $gzip ? 'compressed' : 'uncompressed';
    
    SKIP: {
       
        skip(   "No IO::Zlib - can not read compressed archives",
                4 + 2 * (scalar keys %$expect)  
        ) if( $gzip and !$zlib);

        {
            my $cnt = $tar->read( $type );

            ok( $cnt,                       "Reading $state file using 'read()'" );
            is( $cnt, scalar keys %$expect, "   All files accounted for" );

            for my $file ( keys %$expect ) {
                like( $tar->get_content($file), $expect->{$file},
                        "   Content OK" ); 
            }
        } 

        {
            my @files = Archive::Tar->list_archive( $archive );                  
            ok( scalar @files,                          "Reading $state file using 'list_archive()'" );
            is( scalar @files, scalar keys %$expect,    "   All files accounted for" );

            for my $file ( @files ) {
                ok( $expect->{$file},   "   Found expected file" );
            }
        }         
    }
    
    $gzip++;
}

{
    my $add = File::Spec->catfile( @root, 'b' );

    my @files = $tar->add_files( $add );
    is( scalar @files, 1,                               "Adding file");
    is( $files[0]->name, 'b',                           "   Proper name" );
    is( $files[0]->is_file, 1,                          "   Proper type" );
    like( $files[0]->get_content, qr/^bbbbbbbbbbb\s*$/, "   Content OK" );
}

{
    my @to_add = ( 'a', 'aaaaa' );
    my $obj = $tar->add_data( @to_add );
    ok( $obj,                                       "Adding data" );
    is( $obj->name, $to_add[0],                     "   Proper name" );
    is( $obj->is_file, 1,                           "   Proper type" );
    like( $obj->get_content, qr/^$to_add[1]\s*$/,   "   Content OK" );
}

{
    ok( $tar->rename( 'a', 'e' ),           "Renaming" ); 
    ok( $tar->replace_content( 'e', 'foo'), "Replacing content" ); 
}

{
    my @files = ('b', 'e');
    
    my $cnt = $tar->remove( @files );
    is( $cnt, scalar @files,                            "Removing files" );
    is( scalar $tar->list_files, scalar keys %$expect,  "   Proper files remaining" );
} 

{
    my $out = File::Spec->catfile( @root, 'out.tar' );

    ok( $tar->write($out),  "Writing tarfile using 'write()'" );
    ok( -s $out,            "   File written" );
    unlink $out;
    
    ok( Archive::Tar->create_archive( $out, 0, $0 ),  
        "Writing tarfile using 'create_archive()'" );
    ok( -s $out, "   File written" );
    unlink $out;
    
    SKIP: {
        skip( "No IO::Zlib - can not write compressed archives", 4 ) unless $zlib;
        my $outgz = File::Spec->catfile( @root, 'out.tgz' );

        ok($tar->write($outgz),    "Writing compressed file using 'write()'" );    
        ok( -s $outgz,             "   File written" );
        unlink $outgz;
        
        ok( Archive::Tar->create_archive( $outgz, 1, $0 ),  
            "Writing compressed file using 'create_archive()'" );
        ok( -s $outgz, "   File written" );
        unlink $outgz;
    }
}
 
{
    {
        my @files = $tar->extract();                    
        is( scalar(@files), 2,   "Extracting files using 'extract()'" );
        _check_files( @files );
    }
    {
    
        my @files = Archive::Tar->extract_archive( $archive );       
        is( scalar @files, 2,   "Extracting files using 'extract_archive()'" );
        _check_files( @files );
    }
        
    sub _check_files {
        my @files = @_;
        for my $file ( @files ) {
            ok( $expect->{$file},                           "   Expected file found" );
        
            my $fh; open( $fh, "$file" ) or warn "Error opening file: $!\n";
            ok( $fh,                                        "   Opening file" );
            like( do {local $/; <$fh>}, $expect->{$file},   "   Contents OK" );
        }
    
        unlink $_ for @files;
    }
}    

{
    my @files = $tar->read( $archive, 0, { limit => 1 } );
    is( scalar @files, 1,                               "Limited read" );
    is( (shift @files)->name, (sort keys %$expect)[0],  "   Expected file found" );
}     
