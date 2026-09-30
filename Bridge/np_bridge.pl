use DynaLoader;
my $lib = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();
my $sym = DynaLoader::dl_find_symbol($lib, "np_run") or die "np_run missing";
my $run = DynaLoader::dl_install_xsub("main::np_run", $sym);
&$run();
