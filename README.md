# Copious Magento Tests

Tools and scripts for testing the Magento ecommerce framework

# License

This software is available under the Academic Free License, version 3.0:

http://www.opensource.org/licenses/afl-3.0.php

# [Checkout Simulator](/load-test/checkout_simulator.sh)

This script supports load testing against Magento 1.8 CE and 1.13 EE installations; it forks subprocesses that perform the same HTTP calls as users with browsers. The simulator requires familiarity with the command line to manage and run it.

This script helps to find the ideal and maximum count of orders per hour against an environment. Test outputs and analyses should come from third parties, as this just runs the test loads.

Tested with Ubuntu 12.04 LTS, GNU bash 4.2.25, and curl 7.22.0 (Linux 3.8 kernel) against Magento 1.13.1 EE. This script will probably not work with previous Magento versions as the script looks for and sends a `form_key` parameter.

## Installation

1. Place the `checkout_simulator.sh` file on your test system (ideally not part of the test cluster)
2. Place the `checkout_config` file in the same directory as the above file
3. Make the file executable with `chmod u+x checkout_simulator.sh`
4. Edit the file to adjust its configurations; example: `vi checkout_simulator`
5. Run the script, ideally in a [backgrounded, virtual terminal](https://www.gnu.org/software/screen/) with `./checkout_simulator.sh`

## History

The script was developed to benchmark and optimize [an EE 1.12 cluster](https://gist.github.com/parhamr/6177160) in 2013. For [Magento Imagine 2014](http://www.imagineecommerce.com/) the script was improved and publicly released.

## Issues

No warranty or support is guaranteed.

# See Also

* [Gist of 1.12 cluster configurations](https://gist.github.com/parhamr/6177160)
