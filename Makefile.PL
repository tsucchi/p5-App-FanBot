use inc::Module::Install;
name 'App-FanBot';
all_from 'lib/App/FanBot.pm';

requires 'AnyEvent::Twitter';
requires 'Config::Pit';
requires 'Encode';
requires 'File::Stamped';
requires 'Log::Minimal';
requires 'FindBin';
requires 'File::Basename';
requires 'List::MoreUtils';
requires 'List::Util';
requires 'Class::Accessor::Lite';

tests 't/*.t';
author_tests 'xt';

test_requires 'Test::More';
auto_set_repository;
#auto_include;
WriteAll;
