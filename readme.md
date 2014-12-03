# Fogrunner - Amazon AWS CLI

Initially started as a little side and test project for managing our own AWS EC2 instances, domains and snapshots.
Got more features as we went along and implemented some higher level features compared to the AWS CLI.
Uses the awesome fog library to access AWS. Fogrunner might also be a nice example or starting point for the use of fog.

## Features

* simple use via command line interface
* uses ENV or ~/aws/config for AWS credentials
* connects to multiple AWS regions simultanously
* lists detailed status of all your EC2 instances
* lists names und region of your S3 buckets
* scales your running EC2 instance with just one command (stops, sets new instance type, starts, allocates elastic IP)
* lists all AWS regions
* lists all Route53 DNS records, with regex filtering
* manages snapshots, lists and deletes snapshots, uses 2 different methods for keeping snapshot history
* debug mode

## Installation

Clone the git repository and do a 

````
$ bundle install
````

if you are using bundler to get the gem dependencies.

## AWS Credentials

fogrunner gets your AWS credentials via environment variables or a config file.

### ENV

````
ENV['AWS_ACCESS_KEY']
ENV['AWS_SECRET_KEY']
````

### config file

fogrunner uses the same config file as the AWI CLI, located in ~/.aws/config

````
[default]
aws_access_key_id=XXXXX
aws_secret_access_key=XXXXX
region=eu-west-1

[other profile]
aws_access_key_id=XXXXX
aws_secret_access_key=XXXXX
region=eu-west-1
````

You may specify a config section via --profile option:

````
$ bundle exec ruby fogrunner.rb --config 'other profile' status
````

## Commands and options

Calling via bundler

````
$ bundle exec ruby fogrunner.rb --help
Fogrunner - AWS Simple CLI
(AWS credentials via environment variables AWS_*_KEY or ~/.aws/config)

Usage:
    fogrunner [global options] [command] [command options]

where [command] is one of:
        status: Show EC2 status
        s3status: Show S3 status
        scale: Scale EC2 instance, set new instance type
        regions: Show all regions
        dns: Show DNS records
        snapshots: Show/delete snapshots

where [options] are:
       --debug, -d:   Verbose output
  --region, -r <s>:   Set AWS regions (default: eu-west-1 us-east-1 ap-southeast-1 ap-northeast-1)
 --profile, -p <s>:   Set config section from ~/.aws/config (default: default)
      --dryrun, -y:   Mock & simulate
     --version, -v:   Print version and exit
        --help, -h:   Show this message
````

Use --help for each command for additional command options:

````
$ bundle exec ruby fogrunner.rb scale --help
````

## Instance Name Tag

## Snapshots

We use Eric Hammonds great consistent-snapshot script with xfs filesystems on all our instances. We are running a simple cron job for taking daily snapshots:

````
HOST=`hostname`
sudo ec2-consistent-snapshot --region <region> --mysql --freeze-filesystem <mountpoint> <volumename> --mysql-username <mysqluser> --mysql-password <mysqlpassword> --description "ec2_consistent_snapshot($HOST)"
````

It is important to include the hostname in the snapshot description. fogrunner uses the hostname to associate a snapshot with an EC2 instance. 
You don't have to use consistent-snapshot for fogrunner. But if you would like fogrunner to manage your snapshots you need to set a snapshot description, which allows fogrunner to connect the instance and it's snapshots.

### References

* EC2 consistent snapshot https://github.com/alestic/ec2-consistent-snapshot
* fog - the ruby cloud services library https://github.com/fog/fog
* AWS CLI config http://docs.aws.amazon.com/cli/latest/userguide/cli-chap-getting-started.html


### Contributing

I would like to hear from you. Comments, questions, tips, tests and pull requests are always welcome.

### License

See [License.md](License.md)
