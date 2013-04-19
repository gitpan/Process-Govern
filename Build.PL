
use strict;
use warnings;

use Module::Build 0.3601;


my %module_build_args = (
  "build_requires" => {
    "Module::Build" => "0.3601"
  },
  "configure_requires" => {
    "Module::Build" => "0.3601"
  },
  "dist_abstract" => "Run child process and govern its various aspects",
  "dist_author" => [
    "Steven Haryanto <stevenharyanto\@gmail.com>"
  ],
  "dist_name" => "Process-Govern",
  "dist_version" => "0.08",
  "license" => "perl",
  "module_name" => "Process::Govern",
  "recommends" => {},
  "recursive_test_files" => 1,
  "requires" => {
    "File::Write::Rotate" => "0.07",
    "IPC::Run" => "0.90",
    "Proc::PID::File" => "1.27",
    "Sys::LoadAvg" => "0.03",
    "perl" => "5.010001"
  },
  "script_files" => [
    "bin/govproc"
  ]
);


my $build = Module::Build->new(%module_build_args);

$build->create_build_script;
