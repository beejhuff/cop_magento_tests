#!/bin/bash
#
# This script supports load testing against Magento 1.8 CE and 1.13 EE installations
# It forks subprocesses that perform the same HTTP calls as users with browsers
# Test outputs and analyses should come from third parties; this is just a runner
#
# See https://github.com/copious/cop_magento_tests for additional information
#
# Typical outcome: X orders per hour for environment Y
#
# Tested with Ubuntu 12.04 LTS, GNU bash 4.2.25, and curl 7.22.0 against Magento 1.13.1 EE
#
# This script will probably not work with previous Magento versions as the
# form_key parameter is expected to be present.

# CONFIGURATION OPTIONS
######

# Protocol: http or https
PROTO=http
# Host: domain name, ip address; ports optional
HOST=example.org
# the PROTO and HOST are used like this:
CART_URL=${PROTO}://${HOST}/checkout/cart/
# boolean; toggles a faster test run that’s useful to for environment validation
FASTER=false
# how long to pause in seconds between starting each simulated user (decimals allowed)
# set to 0 for no delay, but this may skew results; values around 1 second seem optimal
INTRA_USER_SLEEP=0.75
# a cURL configuration file for various options: http://curl.haxx.se/docs/manpage.html
CURL_CONFIG_FILE=checkout_config
# a file or full path to log outcomes of subprocesses
LOG_FILE=checkout_simulator.log
# how many of each product to add to the cart?
QTY=1
# URL parameters for the /checkout/onepage/saveMethod/ step
CHECKOUT_METHOD="method=guest"
# URL parameters for the /checkout/onepage/saveShippingMethod/ step
SHIPPING_METHOD="shipping_method=flatrate_flatrate"
# URL parameters for the /checkout/onepage/savePayment/ step
# NOTE: use test cards https://www.paypalobjects.com/en_US/vhelp/paypalmanager_help/credit_card_numbers.htm
PAYMENT_METHOD="payment[method]=checkmo"

if $FASTER
then
  CONCURRENCIES=(1 2 5)
  CONCURRENCY_DURATION=120
else
  # Bash array of counts of threads to run
  CONCURRENCIES=(3 6 12 25 30 35 40 50)
  # how long to run each level of concurrency, in seconds
  CONCURRENCY_DURATION=1200
fi

if $FASTER
then
  PAGE_SLEEP=1
  CHECKOUT_SLEEP=5
  AJAX_SLEEP=$(( $PAGE_SLEEP * 2 ))
  RETRY_COUNT=2
else
  # prime numbers can spread out the load
  # seconds between each page load
  PAGE_SLEEP=1
  # seconds between each checkout step
  CHECKOUT_SLEEP=17
  # seconds between each AJAX call
  AJAX_SLEEP=3
  # how many retries to attempt, if failures are seen
  RETRY_COUNT=5
fi

# Standard HTTP header for HTML requests
HTML_ACCEPT="Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
# HTTP header for AJAX calls
AJAX_ACCEPT="Accept: text/javascript, text/html, application/xml, text/xml, */*"
# Another AJAX header
AJAX_REQUESTED_WITH="X-Requested-With: XMLHttpRequest"
# Another AJAX header
CHECKOUT_REFERER="Referer: ${PROTO}://${HOST}/checkout/onepage/"
# HTTP header for POST
POST_CONTENT_TYPE="Content-type:application/x-www-form-urlencoded; charset=UTF-8"

# This function is called when this script is told to quit
function clean_up {
  echo -e "\n\nPausing to clean up session files…"
  # Kill all sleep operations from the current user
  killall -u `whoami` sleep
  # This *should* wait for all subprocesses to stop
  wait
  rm -f *.cookie
  rm -f *.tmp
  exit
}

# visit 3 products
# add them to the cart
# view the cart
# checkout
# abandon session
timed_shop() {
  # arg 1 is how long to run for
  local MY_DURATION=$1
  # find end time
  local MY_SECONDS_TARGET=$(($SECONDS + $MY_DURATION))
  # random temp/state files
  local RAND=`LC_CTYPE=C tr -dc A-Za-z0-9 < /dev/urandom | head -c 32 | xargs`
  local COOKIE="${RAND}.cookie"
  local TEMPFILE="${RAND}.tmp"

  # Perform the actions for x many seconds
  # Note that if this loop is really long the rate of orders will be skewed
  while [ $SECONDS -le $MY_SECONDS_TARGET ]
  do
    local START=$SECONDS
    echo -e "------\nUser ${RAND} (${2} of ${3})"
    echo "  iteration ends at: ${MY_SECONDS_TARGET}"
    echo "  time elapsed: ${SECONDS}"
    echo -e "  time to shop: ${MY_DURATION}\n"

    # Naively assuming these are writable
    touch $COOKIE
    echo '' > $COOKIE
    touch $TEMPFILE
    echo '' > $TEMPFILE

    ## NEW SESSION
    ######
    load_url $COOKIE "${PROTO}://${HOST}/" > /dev/null 2>&1
    ## CART PAGE
    ######
    load_url $COOKIE "${CART_URL}" > /dev/null 2>&1
    
    ## PRODUCT 1
    ######
    # category
    load_url $COOKIE "${PROTO}://${HOST}/natural-science/science-history.html" > /dev/null 2>&1
    # PDP
    curl -K $CURL_CONFIG_FILE -b $COOKIE -H $HTML_ACCEPT -c $COOKIE ${PROTO}://${HOST}/natural-science/science-history/simple-001196-product.html > $TEMPFILE 2>&1
    # Find the form_key! (feature introduced with 1.13)
    FORM_KEY=`cat $TEMPFILE | grep -F -m 1 'form_key' | sed 's/.*\/form_key\/\([^\/]*\).*/\1/'`
    echo -e "\nFORM_KEY: ${FORM_KEY}" >> $LOG_FILE

    curl -K $CURL_CONFIG_FILE -b $COOKIE -H $HTML_ACCEPT -c $COOKIE ${PROTO}://${HOST}/natural-science/science-history/simple-001196-product.html > $TEMPFILE 2>&1
    # find the cart URL
    CART_ACTION=$(find_cart_url $TEMPFILE)

    sleep $PAGE_SLEEP
    # add to cart
    curl -K $CURL_CONFIG_FILE -b $COOKIE -c $COOKIE --retry $RETRY_COUNT -H $AJAX_ACCEPT -d "form_key=${FORM_KEY}&product=1196&related_product=&qty=${QTY}" ${CART_ACTION} > /dev/null 2>&1
    # cart page
    load_url $COOKIE "${CART_URL}" > /dev/null 2>&1
    # home page
    load_url $COOKIE "${PROTO}://${HOST}/" > /dev/null 2>&1
    
    ## PRODUCT 2
    ######

    # category
    load_url $COOKIE "${PROTO}://${HOST}/philosophy/eastern-philosophy.html" > /dev/null 2>&1
    # PDP; special promo price!
    load_url $COOKIE "${PROTO}://${HOST}/philosophy/eastern-philosophy/simple-002327-product.html" > $TEMPFILE 2>&1
    # find the cart URL
    CART_ACTION=$(find_cart_url $TEMPFILE)

    # add to cart
    curl -K $CURL_CONFIG_FILE -b $COOKIE -c $COOKIE --retry $RETRY_COUNT -H $AJAX_ACCEPT -d "form_key=${FORM_KEY}&product=2327&related_product=&qty=${QTY}" ${CART_ACTION} > /dev/null 2>&1
    # cart page
    load_url $COOKIE "${CART_URL}" > /dev/null 2>&1
    sleep $PAGE_SLEEP

    ## PRODUCT 3
    ######
    
    # category
    load_url $COOKIE "${PROTO}://${HOST}/literature/world-literature/literary-works/russian-literature.html" > /dev/null 2>&1
    # PDP
    load_url $COOKIE "${PROTO}://${HOST}/natural-science/environmental-science/simple-001239-product.html" > $TEMPFILE 2>&1
    # find the cart URL
    CART_ACTION=$(find_cart_url $TEMPFILE)
    
    # add to cart
    curl -K $CURL_CONFIG_FILE -b $COOKIE -c $COOKIE --retry $RETRY_COUNT -H $AJAX_ACCEPT -d "form_key=${FORM_KEY}&product=1239&related_product=&qty=${QTY}" ${CART_ACTION} > /dev/null 2>&1
    # cart page
    load_url $COOKIE "${CART_URL}" > /dev/null 2>&1
    sleep $PAGE_SLEEP

    ## PRODUCT 4
    ######
    
    # category
    load_url $COOKIE "${PROTO}://${HOST}/computer/computer-engineering.html" > /dev/null 2>&1
    # PDP
    load_url $COOKIE "${PROTO}://${HOST}/computer/computer-engineering/simple-001139-product.html" > $TEMPFILE 2>&1
    # find the cart URL
    CART_ACTION=$(find_cart_url $TEMPFILE)
    
    # add to cart
    curl -K $CURL_CONFIG_FILE -b $COOKIE -c $COOKIE --retry $RETRY_COUNT -H $AJAX_ACCEPT -d "form_key=${FORM_KEY}&product=1139&related_product=&qty=${QTY}" ${CART_ACTION} > /dev/null 2>&1
    # cart page
    load_url $COOKIE "${CART_URL}" > /dev/null 2>&1
    sleep $PAGE_SLEEP

    ## PRODUCT 5
    ######
    
    # category
    load_url $COOKIE "${PROTO}://${HOST}/leisure/gardening.html" > /dev/null 2>&1
    # PDP
    load_url $COOKIE "${PROTO}://${HOST}/natural-science/environmental-science/simple-001522-product.html" > $TEMPFILE 2>&1
    # find the cart URL
    CART_ACTION=$(find_cart_url $TEMPFILE)
    
    # add to cart
    curl -K $CURL_CONFIG_FILE -b $COOKIE -c $COOKIE --retry $RETRY_COUNT -H $AJAX_ACCEPT -d "form_key=${FORM_KEY}&product=1522&related_product=&qty=${QTY}" ${CART_ACTION} > /dev/null 2>&1
    # cart page
    load_url $COOKIE "${CART_URL}" > /dev/null 2>&1
    sleep $PAGE_SLEEP

    ## CART, SHIPPING, TAX
    ######

    load_url $COOKIE "${CART_URL}" > /dev/null 2>&1
    sleep $CHECKOUT_SLEEP

    # NOTE: if you have shipping and tax features, test them here

    ## CHECKOUT
    ######
    
    echo -e "\nUser ${RAND} checking out"

    load_url $COOKIE "${PROTO}://${HOST}/checkout/onepage/" > $TEMPFILE 2>&1
    # Find the address ID!
    ADDRESS_ID=`cat $TEMPFILE | grep 'address_id' | sed 's/[^0-9]*//g'`

    curl -K $CURL_CONFIG_FILE -b $COOKIE -c $COOKIE --retry $RETRY_COUNT -H $AJAX_ACCEPT -H $CHECKOUT_REFERER -H $AJAX_REQUESTED_WITH -d $CHECKOUT_METHOD ${PROTO}://${HOST}/checkout/onepage/saveMethod/ > /dev/null 2>&1

    # NOTE: this is where users could sign in or sign up

    load_ajax_checkout $COOKIE"${PROTO}://${HOST}/checkout/onepage/progress/?prevStep=billing" > /dev/null 2>&1

    # Save billing
    sleep $CHECKOUT_SLEEP
    curl -K $CURL_CONFIG_FILE -b $COOKIE -c $COOKIE --retry $RETRY_COUNT -H $AJAX_ACCEPT -H $CHECKOUT_REFERER -H $AJAX_REQUESTED_WITH -d "billing[address_id]=&billing[firstname]=Test&billing[lastname]=Account&billing[company]=&billing[email]=test${RAND}@example.org&billing[street][]=411 SW 6th Ave&billing[street][]=&billing[city]=Portland&billing[region_id]=49&billing[region]=&billing[postcode]=97204&billing[country_id]=US&billing[telephone]=5035551212&billing[fax]=&billing[customer_password]=&billing[confirm_password]=&billing[save_in_address_book]=1&billing[use_for_shipping]=1" ${PROTO}://${HOST}/checkout/onepage/saveBilling/ > /dev/null 2>&1

    # Get additional; this tends to trigger other Magento features
    curl -K $CURL_CONFIG_FILE -b $COOKIE -c $COOKIE --retry $RETRY_COUNT -H $AJAX_ACCEPT -H $CHECKOUT_REFERER -H $AJAX_REQUESTED_WITH -X POST ${PROTO}://${HOST}/checkout/onepage/getAdditional/ > $TEMPFILE 2>&1
    # Find the gift options ID
    GIFT_OPTION_LINES=`grep -F 'giftoptions' $TEMPFILE`
    echo $GIFT_OPTION_LINES > $TEMPFILE
    # NOTE: the vanilla template has one gift option for the cart and each item
    GIFT_OPTION_ID_1=`sed 's/[^0-9]*//g' $TEMPFILE | head -n 1 | tail -n 1`
    GIFT_OPTION_ID_2=`sed 's/[^0-9]*//g' $TEMPFILE | head -n 2 | tail -n 1`
    GIFT_OPTION_ID_3=`sed 's/[^0-9]*//g' $TEMPFILE | head -n 3 | tail -n 1`
    GIFT_OPTION_ID_4=`sed 's/[^0-9]*//g' $TEMPFILE | head -n 4 | tail -n 1`
    GIFT_OPTION_ID_5=`sed 's/[^0-9]*//g' $TEMPFILE | head -n 5 | tail -n 1`
    GIFT_OPTION_ID_6=`sed 's/[^0-9]*//g' $TEMPFILE | head -n 6 | tail -n 1`
    
    # load the progress steps
    load_ajax_checkout $COOKIE "${PROTO}://${HOST}/checkout/onepage/progress/?prevStep=billing" > /dev/null 2>&1
    sleep $PAGE_SLEEP
    load_ajax_checkout $COOKIE "${PROTO}://${HOST}/checkout/onepage/progress/?prevStep=shipping" > /dev/null 2>&1
    sleep $CHECKOUT_SLEEP

    # Save shipping
    curl -K $CURL_CONFIG_FILE -b $COOKIE -c $COOKIE --retry $RETRY_COUNT -H $CHECKOUT_REFERER -H $AJAX_ACCEPT -H $AJAX_REQUESTED_WITH -H $POST_CONTENT_TYPE -d $SHIPPING_METHOD ${PROTO}://${HOST}/checkout/onepage/saveShippingMethod/ > /dev/null 2>&1
    sleep $PAGE_SLEEP
    # load the progress steps
    load_ajax_checkout $COOKIE "${PROTO}://${HOST}/checkout/onepage/progress/?prevStep=shipping_method" > /dev/null 2>&1
    sleep $CHECKOUT_SLEEP

    # Save payment
    curl -K $CURL_CONFIG_FILE -b $COOKIE -c $COOKIE --retry $RETRY_COUNT -H $AJAX_ACCEPT -H $CHECKOUT_REFERER -H $AJAX_REQUESTED_WITH -d $PAYMENT_METHOD ${PROTO}://${HOST}/checkout/onepage/savePayment/ > /dev/null 2>&1
    sleep $PAGE_SLEEP
    # load the progress steps
    load_ajax_checkout $COOKIE "${PROTO}://${HOST}/checkout/onepage/progress/?prevStep=payment" > /dev/null 2>&1
    sleep $CHECKOUT_SLEEP

    # Save order
    curl -K $CURL_CONFIG_FILE -b $COOKIE -c $COOKIE --retry $RETRY_COUNT -H $AJAX_ACCEPT -H $CHECKOUT_REFERER -H $AJAX_REQUESTED_WITH -d $PAYMENT_METHOD ${PROTO}://${HOST}/checkout/onepage/saveOrder/form_key/${FORM_KEY}/ >> $LOG_FILE 2>&1
    sleep $CHECKOUT_SLEEP

    # Load reciept
    load_url $COOKIE "${PROTO}://${HOST}/checkout/onepage/success/" > /dev/null 2>&1
    sleep $CHECKOUT_SLEEP

    # abandon this session
    rm -f $COOKIE
    rm -f $TEMPFILE

    ELAPSED_TIME=$(($SECONDS - $START))

    echo -e "\n\n------\nUser ${RAND} CHECKOUT COMPLETED (in ${ELAPSED_TIME} seconds)\n------\n\n" >> $LOG_FILE
  done
}

function find_cart_url {
  # Argument 1 is the tempfile
  #
  # find the line of HTML containing the cart URL and
  # extract the value of the form action from this line of HTML
  # REVIEW: regular expression is sub-optimal for HTML
  echo `cat $1 | grep -F 'checkout/cart/add' | sed 's/.* action="\([^"]*\)".*/\1/'`
}

function load_url {
  # Argument 1 is the cookie file
  # Argument 2 is the URL
  curl -K $CURL_CONFIG_FILE -H $HTML_ACCEPT --retry $RETRY_COUNT -b $1 -c $1 $2
}

function load_ajax_checkout {
  # Argument 1 is the cookie file
  # Argument 2 is the URL
  curl -K $CURL_CONFIG_FILE --retry $RETRY_COUNT -H $AJAX_ACCEPT -H $CHECKOUT_REFERER -H $AJAX_REQUESTED_WITH -b $1 -c $1 $2
}

# create the log file
touch $LOG_FILE
if [ $? != 0 ];
then
  echo "FATAL: could not write to log file: ${LOG_FILE}"
  exit 1
fi
# clear the log
echo '' > $LOG_FILE

if [ ! -e $CURL_CONFIG_FILE ]
then
  echo ''
  echo "FATAL: ${CURL_CONFIG_FILE} file is not present"
  exit 1
fi

# interrupting signals will be handled as gracefully as possible
trap clean_up SIGHUP SIGINT SIGTERM EXIT

## RUN THE SCRIPT
######

echo -e "\nCheckout simulator\nhost: ${HOST}\n"

# concurrency notes: http://opennomad.com/content/parallelism-or-multiple-threads-bash
for c in "${CONCURRENCIES[@]}"
do
  echo "Shopping as ${c} users for ${CONCURRENCY_DURATION} seconds."
  date
  echo "START: checkout as ${c} users (`date`)" >> $LOG_FILE
  # reset instance counter
  i=1

  START_TIME=$SECONDS
  # perform the actions for x many users
  while [ $i -le $c ]
  do
    ELAPSED_TIME=$(($SECONDS - $START_TIME))
    # fork a process to shop
    TIME_TO_RUN=$(($CONCURRENCY_DURATION - $ELAPSED_TIME))
    timed_shop $TIME_TO_RUN $i $c &
    # increment instance counter
    i=$(( $i + 1))
    # wait for the configured time period
    sleep $INTRA_USER_SLEEP
  done
  # wait for the forked processes to complete
  wait
  message="END: checkout as ${c} users (`date`)"
  echo $message >> $LOG_FILE
  echo -e "${message}\n"
done

echo -e "Done! All concurrency scenarios have run.\n"
exit 0
