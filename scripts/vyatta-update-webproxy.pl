#!/usr/bin/perl
#
# Module: vyatta-update-webproxy.pl
# 
# **** License ****
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 as
# published by the Free Software Foundation.
# 
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
# 
# This code was originally developed by Vyatta, Inc.
# Portions created by Vyatta are Copyright (C) 2008-2010 Vyatta, Inc.
# All Rights Reserved.
# 
# Author: Stig Thormodsrud
# Date: August 2008
# Description: Script to configure webproxy (squid and squidguard).
# 
# **** End License ****
#

use Getopt::Long;
use POSIX;
use File::Basename;

use lib '/opt/vyatta/share/perl5';
use Vyatta::Config;
use Vyatta::TypeChecker;
use Vyatta::Webproxy;
use Vyatta::IpTables::Mgr;

use warnings;
use strict;

# squid globals
my $squid_conf      = '/etc/squid3/squid.conf';
my $local_conf      = '/etc/squid3/local.conf';
my $squid_log       = '/var/log/squid3/access.log';
my $squid_cache_dir = '/var/spool/squid3';
my $squid_def_fs    = 'ufs';
my $squid_def_port  = 3128;
my $squid_chain     = 'WEBPROXY_CONNTRACK';

# squidGuard globals
my $squidguard_conf          = '/etc/squid/squidGuard.conf';
my $squidguard_redirect_def  = 'http://www.google.com';
my $squidguard_enabled       = 0;

# global hash of ipv4 addresses on the system
my %config_ipaddrs = ();


sub squid_get_constants {
    my $output;
    
    my $date = `date`; chomp $date;
    $output  = "#\n# autogenerated by vyatta-update-webproxy.pl\n#\n\n";

    $output .= "acl manager proto cache_object\n";
    $output .= "acl localhost src 127.0.0.1/32\n";
    $output .= "acl to_localhost dst 127.0.0.0/8\n";
    $output .= "acl net src 0.0.0.0/0\n";
    $output .= "acl SSL_ports port 443\n";
    $output .= "acl Safe_ports port 80          # http\n";
    $output .= "acl Safe_ports port 21          # ftp\n";
    $output .= "acl Safe_ports port 443         # https\n";
    $output .= "acl Safe_ports port 70          # gopher\n";
    $output .= "acl Safe_ports port 210         # wais\n";
    $output .= "acl Safe_ports port 1025-65535  # unregistered ports\n";
    $output .= "acl Safe_ports port 280         # http-mgmt\n";
    $output .= "acl Safe_ports port 488         # gss-http\n";
    $output .= "acl Safe_ports port 591         # filemaker\n";
    $output .= "acl Safe_ports port 777         # multiling http\n";
    $output .= "acl CONNECT method CONNECT\n\n";
    
    system("touch $squid_log");
    system("chown proxy.adm $squid_log");

    return $output;
}

sub squid_get_http_access_constants {
    my $output;

    $output  = "http_access allow manager localhost\n";
    $output .= "http_access deny manager\n";
    $output .= "http_access deny !Safe_ports\n";
    $output .= "http_access deny CONNECT !SSL_ports\n";
    $output .= "http_access allow localhost\n";
    $output .= "http_access allow net\n";
    $output .= "http_access deny all\n\n";

    return $output
}

sub squid_get_config_acls {
    my $config = new Vyatta::Config;
    my $output = '';

    # add domain-block
    $config->setLevel('service webproxy domain-block'); 
    my @domains_block = $config->returnValues();
    if (scalar(@domains_block) > 0) {
	foreach my $domain (@domains_block) {
	    $output .= "acl BLOCKDOMAIN dstdomain $domain\n";
	}
	$output .= "http_access deny BLOCKDOMAIN\n\n";
    }

    # add domain-noncache
    $config->setLevel('service webproxy domain-noncache'); 
    my @domains_noncache = $config->returnValues();
    if (scalar(@domains_noncache) > 0) {
	foreach my $domain (@domains_noncache) {
	    $output .= "acl NOCACHE dstdomain $domain\n";
	}
	$output .= "no_cache deny NOCACHE\n\n";
    }
    
    return $output;
}

sub squid_validate_conf {
    my $config = new Vyatta::Config;

    #
    # Need to validate the config before issuing any iptables 
    # commands.
    #
    $config->setLevel('service webproxy');
    my $cache_size = $config->returnValue('cache-size');
    if (! defined $cache_size) {
	print "Must define cache-size\n";
	exit 1;
    }

    my $append_domain = $config->returnValue('append-domain');
    if (defined $append_domain) {
	if ($append_domain =~ /^\.(.*)$/) {
	    my @addrs = gethostbyname($1) or 
		print "Warning: can't resolve $1: $!\n";
	} else {
	    print "Domain [$append_domain] must begin with '.'\n";
	    exit 1;
	}
    }

    $config->setLevel('service webproxy listen-address');
    my @ipaddrs = $config->listNodes();
    if (scalar(@ipaddrs) <= 0) {
	print "Must define at least 1 listen-address\n";
	exit 1;
    }

    foreach my $ipaddr (@ipaddrs) {
	if (!defined $config_ipaddrs{$ipaddr}) {
	    print "listen-address [$ipaddr] is not a configured address\n";
	    exit 1;
	}
	# does it need to be primary ???
    }

    #check for nameserver
    if (system('grep -cq nameserver /etc/resolv.conf 2> /dev/null')) {
	print "Warning: webproxy may not work properly without a nameserver\n";
    }

    return 0;
}

sub squid_get_values {
    my $output = '';
    my $config = new Vyatta::Config;

    $config->setLevel('service webproxy');
    my $o_def_port = $config->returnOrigValue('default-port');
    my $n_def_port = $config->returnValue('default-port');
    $o_def_port = $squid_def_port if ! defined $o_def_port;
    $n_def_port = $squid_def_port if ! defined $n_def_port;

    my @block_mime_types = $config->returnValues('reply-block-mime');
    if (scalar(@block_mime_types)) {
	foreach my $mime (@block_mime_types) {
	    $output .= "acl BLOCK_MIME rep_mime_type $mime\n";
	}
	$output .= "http_reply_access deny BLOCK_MIME\n\n";
    }

    my $cache_size = $config->returnValue('cache-size');
    $cache_size = 100 if ! defined $cache_size;
    if ($cache_size > 0) {
	$output .= "cache_dir $squid_def_fs $squid_cache_dir ";
        $output .= "$cache_size 16 256\n";
    } else {
	# disable caching
	$output .= "cache_dir null $squid_cache_dir\n";
    }

    if ($config->exists('disable-access-log')) {
	$output .= "access_log none\n\n";
    } else {
	$output .= "access_log $squid_log squid\n\n";
    }

    # by default we'll disable the store log
    $output .= "cache_store_log none\n\n";

    my $append_domain = $config->returnValue('append-domain');
    if (defined $append_domain) {
	$output .= "append_domain $append_domain\n\n";
    }

    my $num_nats = 0;
    $config->setLevel('service webproxy listen-address');
    my %ipaddrs_status = $config->listNodeStatus();
    my @ipaddrs = sort keys %ipaddrs_status;
    foreach my $ipaddr (@ipaddrs) {
	my $status = $ipaddrs_status{$ipaddr};
	#print "$ipaddr = [$status]\n";
	$status = 'changed' if $n_def_port != $o_def_port and 
	                       $status eq 'static';

	my $o_port = $config->returnOrigValue("$ipaddr port");	
	my $n_port = $config->returnValue("$ipaddr port");	
	$o_port = $o_def_port if ! defined $o_port;	
	$n_port = $n_def_port if ! defined $n_port;	

	my $o_dt = $config->existsOrig("$ipaddr disable-transparent");
	my $n_dt = $config->exists("$ipaddr disable-transparent");
	my $transparent = 'transparent';
	$transparent = '' if $n_dt;
	if ($status ne 'deleted') {
	    $num_nats++ if $transparent eq 'transparent';
	    $output .= "http_port $ipaddr:$n_port $transparent\n";
	}

	my $intf = $config_ipaddrs{$ipaddr};

	#
	# handle NAT rule for transparent
	#
        my $A_or_D = undef;
	if ($status eq 'added' and !defined $n_dt) {
	    $A_or_D = 'A';
	} elsif ($status eq 'deleted' and !defined $o_dt) {
	    $A_or_D = 'D';
	} elsif ($status eq 'changed') {
	    $o_dt = 0 if !defined $o_dt;
	    $n_dt = 0 if !defined $n_dt;
	    if ($o_dt ne $n_dt) {
		if ($n_dt) {
		    $A_or_D = 'D';
		} else {
		    $A_or_D = 'A';
		}
	    }
	    #
	    #handle port # change
	    #
	    if ($o_port ne $n_port and !$o_dt) {
		my $cmd = "sudo iptables -t nat -D WEBPROXY -i $intf ";
		$cmd   .= "-p tcp --dport 80 -j REDIRECT --to-port $o_port";
		#print "[$cmd]\n";
		my $rc = system($cmd);
		if ($rc) {
		    print "Error removing port redirect [$!]\n";
		}		
		if (!$n_dt) {
		    $A_or_D = 'A';		    
	        } else {
		    $A_or_D = undef;
		}
	    }
	}
	if (defined $A_or_D) {
	    ipt_enable_conntrack('iptables', $squid_chain) if $A_or_D eq 'A';
	    my $cmd = "sudo iptables -t nat -$A_or_D WEBPROXY -i $intf ";
	    $cmd   .= "-p tcp --dport 80 -j REDIRECT --to-port $n_port";
	    #print "[$cmd]\n";
	    my $rc = system($cmd);
	    if ($rc) {
		my $action = 'adding';
		$action = 'deleting' if $A_or_D eq 'D';
		print "Error $action port redirect [$!]\n";
	    }
	} 
    }
    $output .= "\n";

    ipt_disable_conntrack('iptables', $squid_chain) if $num_nats < 1;

    #
    # default to NOT insert the client address in X-Forwarded-For header
    #
    $output .= "forwarded_for off\n\n";

    #
    # check if squidguard is configured
    #
    $config->setLevel('service webproxy url-filtering');
    if ($config->exists('disable')) {
        $squidguard_enabled = 0;
        return $output;
    }
    if ($config->exists('squidguard')) {
	$squidguard_enabled = 1;
	$output .= "redirect_program /usr/bin/squidGuard -c $squidguard_conf\n";
	$output .= "redirect_children 8\n";
	$output .= "redirector_bypass on\n\n";
    }

    return $output;
}

sub squidguard_gen_cron {
    my ($update_hour) = @_;

    return if ! defined $update_hour;

    $update_hour =~ s/^0*//;
    $update_hour = 0 if ($update_hour eq '');

    my $file = "/etc/cron.hourly/vyatta-update-urlfilter";
    my $output;
    $output  = '#!/bin/bash' . "\n#\n";
    $output .= '# autogenerated by vyatta-update-webproxy.pl' ."\n#\n";
    $output .= '# cron job to automatically update the url-filter db' . "\n";
    $output .= '#' . "\n\n";
    $output .= 'cur_hour=$(date +%-H)' . "\n";
    $output .= 'if [ "$cur_hour" != "' . $update_hour . '" ]; then' . "\n";
    $output .= '  # not the right hour. do nothing.' . "\n";
    $output .= '  exit 0' . "\n";
    $output .= 'fi' . "\n";
    if (my $mode = squidguard_use_ec()) {
        $output .= '/opt/vyatta/sbin/vg update --quiet';
        $output .= ' -D' if $mode eq 'net-only';
        $output .= "\n";
    } else {
        $output .= '/opt/vyatta/bin/sudo-users/vyatta-sg-blacklist.pl ';
        $output .= ' --auto-update-blacklist' . "\n";
    }

    webproxy_write_file($file, $output); 
    system("chmod 755 $file");
}

sub squidguard_gen_safesearch {
    my $output = '';
    my @lines = squidguard_get_safesearch_rewrites();
    return $output if scalar(@lines) < 1;

    $output = "rewrite safesearch {\n";
    foreach my $line (@lines) {
        $output .= "\t$line\n";
    }
    $output .= "\tlog\trewrite.log\n";
    $output .= "}\n\n";
    return $output;
}

sub squidguard_validate_filter {
    my ($config, $path, $group, $blacklist_installed) = @_;

    my @blacklists   = squidguard_get_blacklists();
    my %is_blacklist = map { $_ => 1 } @blacklists;

    $config->setLevel('service webproxy url-filtering squidguard');
    my @time_periods  = $config->listNodes('time-period');
    my %time_hash     = map { $_ => 1 } @time_periods;
    my @source_groups = $config->listNodes('source-group');
    my %source_hash   = map { $_ => 1 } @source_groups;

    if ($group ne 'default') {
	$config->setLevel("$path source-group");
	my $source = $config->returnValue();
	die "Must set source-group for [$group]\n" if ! $source;
	die "rule [$group] source-group [$source] not defined\n" 
	    if ! $source_hash{$source};
	$config->setLevel("$path time-period");
	my $time_period = $config->returnValue();
	if (defined $time_period and $time_period ne '') {
	    $time_period =~ s/^!(.*)$/$1/;  # remove '!' if there
	    die "rule [$group] time-period [$time_period] not defined\n"
		if ! $time_hash{$time_period};
	}
    }

    #
    # check for valid block-category
    #
    $config->setLevel("$path block-category");
    my @block_category = $config->returnValues();
    my %is_block       = map { $_ => 1 } @block_category; 
    foreach my $category (@block_category) {
	if (! defined $is_blacklist{$category}) {
            if (squidguard_use_ec()) {
                my $ec_cat = squidguard_ec_name2cat($category);
                next if defined $ec_cat;
            }
	    print "Unknown block-category [$category] for policy [$group]\n";
	    exit 1;
	}
    }

    #
    # check for valid allow-category
    #
    $config->setLevel("$path allow-category");
    my @allow_category = $config->returnValues();
    my %is_allow       = map { $_ => 1 } @allow_category; 
    foreach my $category (@allow_category) {
	if (! defined $is_blacklist{$category}) {
            if (squidguard_use_ec()) {
                my $ec_cat = squidguard_ec_name2cat($category);
                next if defined $ec_cat;
            }
	    print "Unknown allow-category [$category] for policy [$group]\n";
	    exit 1;
	}
    }

    if (! squidguard_use_ec()) {
        my $db_dir = squidguard_get_blacklist_dir();
        foreach my $category (@block_category, @allow_category) {
            my ($domains, $urls, $exps) = 
                squidguard_get_blacklist_domains_urls_exps($category);
            my $db_file = '';
            if (defined $domains) {
                $db_file = "$db_dir/$domains.db";
                if (! -e $db_file) {
                    print "Missing DB for [$domains].\n";
                    print "Try running \"update webproxy blacklists\"\n";
                    exit 1;
                }
            }
            if (defined $urls) {
                $db_file = "$db_dir/$urls.db";
                if (! -e $db_file) {
                    print "Missing DB for [$urls].\n";
                    print "Try running \"update webproxy blacklists\"\n";
                    exit 1;
                }
            }
            # is it needed for exps?
        }
    }

    $config->setLevel("$path log");
    my @log_category = $config->returnValues();
    foreach my $log (@log_category) {
	if (! defined $is_blacklist{$log} and $log ne 'all') {
	    print "Log [$log] is not a valid blacklist category\n";
	    exit 1;
	}
    }
    return;
}

sub squidguard_validate_conf {
    my $config = new Vyatta::Config;
    my $path = 'service webproxy url-filtering squidguard';

    $config->setLevel('service webproxy url-filtering');
    return 0 if ! $config->exists('squidguard');

    my $blacklist_installed = 1;
    if (!squidguard_is_blacklist_installed()) {
	print "Warning: no blacklists installed\n";
	$blacklist_installed = 0;
    }

    $config->setLevel($path);
    my $redirect_url = $config->returnValue('redirect-url');
    $redirect_url    = $squidguard_redirect_def if ! defined $redirect_url;
    if ($redirect_url !~ /^https?:\/\/.*/) {
	print "Invalid redirect-url [$redirect_url]. ";
        print "Should start with \"http://\"\n";
	exit 1;
    }

    # validate default filtering
    squidguard_validate_filter($config, $path, 'default', 
			       $blacklist_installed);

    # validate group filtering
    $path = "$path rule";
    $config->setLevel($path);    
    my @groups = $config->listNodes();
    foreach my $group (@groups) {
	squidguard_validate_filter($config, "$path $group", $group,
				   $blacklist_installed);
    }

    return 0;
}

sub squidguard_get_constants {
    my $output;
    my $date = `date`; chomp $date;
    $output  = "#\n# autogenerated by vyatta-update-webproxy.pl\n#\n\n";

    $output .= "dbhome /var/lib/squidguard/db\n";
    $output .= "logdir /var/log/squid\n\n";

    $output .= squidguard_gen_safesearch();

    return $output;
}

sub squidguard_generate_local {
    my ($action, $type, $group, @local_values) = @_;

    my $db_dir       = squidguard_get_blacklist_dir();
    my $local_action = "local-$action";
    $local_action    = "local-$action-$group";
    my $dir          = "$db_dir/$local_action";

    if (scalar(@local_values) <= 0) {
	system("rm -rf $dir") if -d $dir;
	return;
    }

    system("mkdir $dir") if ! -d $dir;
    my $file  = "$dir/$type";
    my $value = join("\n", @local_values) . "\n";
    if (webproxy_write_file($file, $value)) {
	system("chown -R proxy.proxy $dir > /dev/null 2>&1");
	system("touch $dir/local") if ! -e "$dir/local";
	squidguard_generate_db(0, "local-$action-$group", $group);
    }
    return $local_action;
}

sub get_time_segments {
    my ($time_string) = @_;
    
    $time_string =~ s/\s//g;
    my @segments = split ',', $time_string;
    push @segments, $time_string if scalar(@segments) < 1;
    return @segments;
}

my %days_hash = (
    'Sun'      => 's',
    'Mon'      => 'm',
    'Tue'      => 't',
    'Wed'      => 'w',
    'Thu'      => 'h',
    'Fri'      => 'f',
    'Sat'      => 'a',
    'weekdays' => 'mtwhf',
    'weekend'  => 'sa',
    'all'      => 'smtwhfa',
);

sub fix_time_segment {
    my ($segment) = @_;

    return $segment;
}

sub squidguard_get_times {
    my ($config, $path) = @_;

    my $output = '';
    $config->setLevel("$path time-period");
    my @time_periods = $config->listNodes();
    return (undef, undef) if scalar(@time_periods) < 1;

    foreach my $time_period (@time_periods) {
	$output .= "time $time_period {\n";
	$config->setLevel("$path time-period $time_period days");	
	my @days = $config->listNodes();
	foreach my $day (@days) {
	    my $day_str = $days_hash{$day};
	    $config->setLevel("$path time-period $time_period days $day");	
	    my $times    = $config->returnValue('time');
	    my @segments = get_time_segments($times);
	    my $time_str;
	    foreach my $segment (@segments) {
		$segment = fix_time_segment($segment);
		$time_str .= "$segment ";
	    }
	    $output .= "\tweekly $day_str\t$time_str\n";
	}
	$output .= "}\n";
    }
    $output .= "\n";
    return ($output, @time_periods);
}

sub squidguard_get_source {
    my ($config, $path, $policy) = @_;

    my $output = '';
    $config->setLevel("$path rule $policy");
    my $source = $config->returnValue('source-group');

    $output .= "src $source-$policy {\n";
    $config->setLevel("$path source-group $source address");	
    my @addrs = $config->returnValues();
    if (scalar(@addrs) > 0) {
	foreach my $addr (@addrs) {
	    $output .= "\tip $addr\n";
	}
    }

    $config->setLevel("$path source-group $source domain");	
    my @domains = $config->returnValues();
    if (scalar(@domains) > 0) {
	foreach my $domain (@domains) {
	    $output .= "\tdomain $domain\n";
	}
    }
    $output .= "}\n";
    return $output;
}

sub squidguard_get_dests {
    my ($config, $path, $group) = @_;

    my $output = '';


    $config->setLevel('service webproxy listen-address');
    my @listen_addrs = $config->listNodes();

    # get local-ok
    $config->setLevel("$path local-ok");
    my @local_ok_sites = $config->returnValues();
    push @local_ok_sites, @listen_addrs;
    my $local_ok       = squidguard_generate_local('ok', 'domains', $group,
						   @local_ok_sites);

    # get local-ok-url
    $config->setLevel("$path local-ok-url");
    my @local_ok_url_sites = $config->returnValues();
    push @local_ok_url_sites, @listen_addrs;
    my $local_ok_url       = squidguard_generate_local('ok-url', 'urls', 
                                                       $group,
                                                       @local_ok_url_sites);
 
    # get local-block
    $config->setLevel("$path local-block");
    my @local_block_sites = $config->returnValues();
    my $local_block       = squidguard_generate_local('block', 'domains',
						      $group,
						      @local_block_sites);

    # get local-block-url
    $config->setLevel("$path local-block-url");
    my @local_block_url_sites = $config->returnValues();
    my $local_block_url       = squidguard_generate_local('block-url', 'urls',
                                                         $group,
 						         @local_block_url_sites);

    # get local-block-keyword
    $config->setLevel("$path local-block-keyword");
    my @local_block_keywords = $config->returnValues();
    my $local_block_keyword  = squidguard_generate_local('block-keyword', 
							 'expressions',
							 $group,
							 @local_block_keywords);

    # get block-category
    $config->setLevel("$path block-category");
    my @block_category = $config->returnValues();
    my %is_block       = map { $_ => 1 } @block_category;    

    # get allow-category
    $config->setLevel("$path allow-category");
    my @allow_category = $config->returnValues();
    my %is_allow       = map { $_ => 1 } @allow_category;    

    # get categories to log
    $config->setLevel("$path log");
    my @log_category = $config->returnValues();
    my $log_file = undef;
    if (scalar(@log_category) > 0) {
	$log_file = squidguard_get_blacklist_log();
	system("touch $log_file");
	system("chown proxy.adm $log_file");
    }
    my %is_logged    = map { $_ => 1 } @log_category;    

    my @blacklists   = squidguard_get_blacklists();
    my %is_blacklist = map { $_ => 1 } @blacklists;

    if ($local_ok) {
	$output .= squidguard_build_dest('local-ok', 0, $group);
    }
    if ($local_ok_url) {
	$output .= squidguard_build_dest('local-ok-url', 0, $group);
    }
    my $log = 0;
    if ($local_block) {
	$log = 1 if $is_logged{all} or $is_logged{"local-block-$group"};
	$output .= squidguard_build_dest('local-block', $log, $group);
    }
    if ($local_block_url) {
	$log = 1 if $is_logged{all} or $is_logged{"local-block-url-$group"};
	$output .= squidguard_build_dest('local-block-url', $log, $group);
    }
    $log = 0;
    if (defined $local_block_keyword) {
	$log = 1 if $is_logged{all} or $is_logged{"local-block-keywork-$group"};
	$output .= squidguard_build_dest('local-block-keyword', $log, $group);
    }

    $config->setLevel('service webproxy url-filtering squidguard');
    my $ec = undef;
    $ec = 1 if $config->exists('vyattaguard');

    foreach my $category (@block_category) {
	next if $category eq '';
	$log = 0;
	$log = 1 if $is_logged{all} or $is_logged{$category};
	$output .= squidguard_build_dest($category, $log, $group, $ec);
    }
    foreach my $category (@allow_category) {
	next if $category eq '';
	$log = 0;  # don't log allows
	$output .= squidguard_build_dest($category, $log, $group, $ec);
    }

    return $output;
}

sub squidguard_get_acls {
    my ($config, $path, $policy, $time_periods) = @_;

    my $output = "";
    $config->setLevel($path);
    my $source;
    if ($policy eq 'default') {
	$source = $policy;
    } else {
	$source = $config->returnValue('source-group');
	$source = "$source-$policy";
    } 

    my $time_period = $config->returnValue('time-period');
    if ($time_period) {
	$time_period =~ s/\s//g;
	my $neg_time = 0;
	if ($time_period =~ /^\!/) {
	    $neg_time = 1;
	    $time_period =~ s/!//;
	}
	my %time_hash = map { $_ => 1 } @$time_periods;
	if (! $time_hash{$time_period}) {
	    die "Error: unknown time-period [$time_period] for [$policy]\n";
	}
	if ($neg_time) {
	    $output .= "\t$source outside $time_period {\n";
	} else {
	    $output .= "\t$source within $time_period {\n";
	}
    } else {
	$output .= "\t$source {\n";
    }

    $output .= "\t\trewrite safesearch\n" 
        if $config->exists('enable-safe-search');
    
    # order of evaluation
    # 1) local-ok     (local override, whitelist)
    # 2) local-ok-url (local override, whitelist)
    # 3) local-block  (local override, blacklist)
    # 4) local-block-url      (local override, blacklist)
    # 5) in-addr      (allow-ipaddr-url or not)
    # 6) block-categories     (blacklist category)
    # 7) allow-categories     (blacklist category)
    # 8) local-block-keywords (local regex blacklist)
    # 9) default-action (allow|block = all|none)

    my $acl = "\t\tpass ";
    $config->setLevel($path);
    # 1)
    $acl .= "local-ok-$policy ";
    # 2)
    $acl .= "local-ok-url-$policy " if $config->exists('local-ok-url');
    # 3)
    $acl .= "!local-block-$policy " if $config->exists('local-block');
    # 4)
    $acl .= "!local-block-url-$policy " if $config->exists('local-block-url');
    # 5)
    $acl .= "!in-addr "             if ! $config->exists('allow-ipaddr-url');
    # 6)
    my @block_cats = $config->returnValues('block-category');
    if (scalar(@block_cats) > 0) {
	my $block_conf = '';
	foreach my $cat (@block_cats) {
	    $block_conf .= "!$cat-$policy ";
	}
	$acl .= $block_conf;
    }
    # 7)
    my @allow_cats = $config->returnValues('allow-category');
    if (scalar(@allow_cats) > 0) {
	my $allow_conf = '';
	foreach my $cat (@allow_cats) {
	    $allow_conf .= "$cat-$policy ";
	}
	$acl .= $allow_conf;
    }

    # 8)
    $acl .= "!local-block-keyword-$policy " if 
	$config->exists('local-block-keyword');
    # 9)
    my $def_action = $config->returnValue('default-action');
    if (! defined $def_action or $def_action eq 'allow') {
	$acl .= 'all';
    } else {
	$acl .= 'none';
    }
    $output .= "$acl\n";

    # add redirect url
    my $redirect_url = $config->returnValue('redirect-url');
    if ($policy eq 'default') {
	# Only the default policy needs to have some redirect url.  If
        # the redirect url is not defined for a rule, then it
	# will use the default.
	$redirect_url = $squidguard_redirect_def if ! defined $redirect_url;
    }
    $output .= "\t\tredirect 302:$redirect_url\n" if $redirect_url;

    # check if log all is defined
    $config->setLevel("$path log");
    my @log_category = $config->returnValues();
    my %is_logged    = map { $_ => 1 } @log_category;  
    if ($is_logged{'all'}) {
	my $log_file = squidguard_get_blacklist_log();
	my $log = basename($log_file);
	$output .= "\t\tlog $log\n";
    }
    $output .= "\t}\n\n";

    return $output;
}

sub squidguard_get_values {
    my $output = "";
    my $config = new Vyatta::Config;

    my $path = 'service webproxy url-filtering squidguard';

    # generate time conf
    my ($time_conf, @time_periods) = squidguard_get_times($config, $path);
    $output .= $time_conf if $time_conf;

    $config->setLevel("$path rule");
    my @policys = $config->listNodes();
    @policys = sort @policys;

    # generate source conf for all rules
    my @sources = ();
    foreach my $policy (@policys) {
	my $source_conf  = squidguard_get_source($config, $path, $policy);
	$output .= $source_conf if $source_conf;
    }
 
    # generate dest conf (for all default & rules)
    foreach my $policy ('default', @policys) {
	my $tmp_path = $path;
	$tmp_path .= " rule $policy" if $policy ne 'default';
	my $dests_conf = squidguard_get_dests($config, $tmp_path, $policy);
	$output .= $dests_conf if $dests_conf;  
    }
    
    # generate acl conf (for all rules & default)
    $output .= "acl {\n"; 
    foreach my $policy (@policys, 'default') {
	my $tmp_path = $path;
	$tmp_path .= " rule $policy" if $policy ne 'default';
	my $acl_conf = squidguard_get_acls($config, $tmp_path, $policy
					   , \@time_periods, \@sources);
	$output .= $acl_conf if $acl_conf;
    }
    $output .= "}\n";

    # auto update
    $config->setLevel("$path auto-update");
    my $update_hour = $config->returnValue('update-hour');
    squidguard_gen_cron($update_hour);
 
    return $output;
}


#
# main
#
my ($setup_webproxy, $update_webproxy, $stop_webproxy, $check_time, 
    $check_source_group, @delete_local);

GetOptions("setup!"                => \$setup_webproxy,
           "update!"               => \$update_webproxy,
           "stop!"                 => \$stop_webproxy,
	   "check-time=s"          => \$check_time,
	   "check-source-group=s"  => \$check_source_group,
	   "delete-local=s{3}"     => \@delete_local,
);

#
# make a hash of ipaddrs => interface
#
my @lines = `ip addr show | grep 'inet '`;
chomp @lines;
foreach my $line (@lines) {
    if ($line =~ /inet\s+([0-9.]+)\/.*\s([\w.]+)$/) {
	$config_ipaddrs{$1} = $2;
    }
}

if ($setup_webproxy) {
    system("sudo iptables -t nat -N WEBPROXY");
    system("sudo iptables -t nat -I VYATTA_PRE_DNAT_HOOK 1 -j WEBPROXY");
    exit 0;
}

if ($update_webproxy) { 
    my $config;

    squid_validate_conf();
    squidguard_validate_conf();
    $config  = squid_get_constants();
    $config .= squid_get_config_acls();
    $config .= squid_get_http_access_constants();
    $config .= squid_get_values();
    webproxy_write_file($squid_conf, $config);
    webproxy_append_file($squid_conf, $local_conf);
    if ($squidguard_enabled) {
	my $config2;
	$config2  = squidguard_get_constants();
	$config2 .= squidguard_get_values();
	webproxy_write_file($squidguard_conf, $config2);
    }
    squid_restart(1);
    exit 0;
}

if ($stop_webproxy) {
    #
    # Need to call squid_get_values() to delete the NAT rules
    #
    squid_get_values();
    webproxy_delete_all_local();
    system("rm -f $squid_conf $squidguard_conf");
    system("touch $squid_conf $squidguard_conf");
    system("chown proxy $squid_conf $squidguard_conf");
    squid_stop();
    system("sudo iptables -t nat -D VYATTA_PRE_DNAT_HOOK -j WEBPROXY");
    system("sudo iptables -t nat -F WEBPROXY");
    system("sudo iptables -t nat -X WEBPROXY");
    exit 0;
}

if (scalar(@delete_local) == 3) {
    my ($policy, $category, $value) = @delete_local;
    webproxy_delete_local_entry("$policy-$category", $value);
    exit 0;
}

sub validate_time {
    my ($value) = @_;

    my ($hour, $minute);
    if ($value =~ /:/) {
	if ($value =~ /([\d]+):([\d]+)/) {
	    ($hour, $minute) = ($1, $2);
	    if ($minute < 0 or $minute > 59) {
		print "[$value] = [$minute] must between 0-59\n";
		exit 1;
	    }
	} else {
	    print "invalid time format [$value]\n";
	    exit 1;
	}
    } else {
	exit 1;
    }
    if ($hour < 0 or $hour > 24) {
	print "[$value] = [$hour] must between 0-24\n";
	exit 1;
    }
    return;
}

if ($check_time) {
    my @segments = get_time_segments($check_time);
    foreach my $segment (@segments) {
	if ($segment =~ /(\d\d:\d\d)-(\d\d:\d\d)/) {
	    my ($start, $stop) = ($1, $2);
	    validate_time($start);
	    validate_time($stop);
	} else {
	    print "invalid time format [$segment]\n";
	    exit 1;
	}
    }
    exit 0;
}

if ($check_source_group) {
    if (!Vyatta::TypeChecker::validate_iptables4_addr($check_source_group)) {
	print "ipvalid source group address [$check_source_group]\n";
	exit 1;
    }
    if ($check_source_group =~ /\!/) {
	print "ipvalid source group address [$check_source_group]\n";
	exit 1;
    }
    exit 0;
}

exit 1;

# end of file
