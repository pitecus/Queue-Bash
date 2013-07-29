# Queue Bash
A queue system to deploy packages in multiples servers concurrently.

This script runs an install script (in this example, "yum") simultaneously in multiple servers.

Yes, there is other languages that provide queue system, but I had the restriction to use Bash, so I accepted the challenge and create this script.

It expects the follow parameters:

### Param1: List of hosts, comma separated, no spaces.
### Param2: List of packages, comma separated, no spaces.
### Param3: Deployer User - The user that will ssh remotely to the servers and install the packages.
### Param4: Queue size - How many jobs will run simultaneously per queue. Note que queue size 0 means that the jobs will run one after the other.

The hostnames has the follow pattern:
"server-name"."environment"."datacenter"-domain.com

The way that the script works is creating one queue per datacenter. Then it will deploy on all servers.

Let me know if you come across with a bug or questions or improvements.
