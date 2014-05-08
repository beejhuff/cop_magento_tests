#!/bin/bash
#
# This script supports load testing against Magento 1.8 CE and 1.13 EE installations;
# it forks subprocesses that perform the same HTTP calls as users with browsers.
# Test outputs and analyses should come from third parties; this is just a runner.
#
# See https://github.com/copious/cop_magento_tests for additional information.
#
# Typical outcome: X orders per hour for environment Y.
#
# Tested with Ubuntu 12.04 LTS, GNU bash 4.2.25, and curl 7.22.0 against Magento 1.13.1 EE.
#
# This script will probably not work with previous Magento versions as the
# form_key parameter is expected to be present.

# CONFIGURATION OPTIONS
######

# Debug mode is noisy
DEBUG=false
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
# a file or full path to store ids of subprocesses
PID_FILE=checkout_simulator.pid
# how many of each product to add to the cart?
QTY=1
# URL parameters for the /checkout/onepage/saveMethod/ step
CHECKOUT_METHOD="method=guest"
# URL parameters for the /checkout/onepage/saveShippingMethod/ step
SHIPPING_METHOD="shipping_method=flatrate_flatrate"
# URL parameters for the /checkout/onepage/savePayment/ step
# NOTE: use test cards https://www.paypalobjects.com/en_US/vhelp/paypalmanager_help/credit_card_numbers.htm
PAYMENT_METHOD="payment[method]=checkmo"

echo -e "\nCheckout simulator\nhost: ${HOST}\n"

if $FASTER
then
  CONCURRENCIES=(1 2 4)
  CONCURRENCY_DURATION=300
else
  # Bash array of counts of threads to run
  CONCURRENCIES=(10 20 40 60 80 100 120 140)
  # how long to run each level of concurrency, in seconds
  CONCURRENCY_DURATION=1800
fi

if $DEBUG
then
  FASTER=true
  CONCURRENCIES=(1)
  CONCURRENCY_DURATION=300
  echo -e "DEBUG MODE\n"
fi

if $FASTER
then
  PAGE_SLEEP=0.25
  CHECKOUT_SLEEP=2
  AJAX_SLEEP=`bc -l <<< "$PAGE_SLEEP * 2"`
  RETRY_COUNT=2
  echo -e "FAST MODE\n"
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
  # check if this process has forked children
  job_count=`jobs -p | wc -l`
  if [ $job_count -gt 0 ]
  then
    printf "\n\nCleaning up session files…"
    # Kill all sub processes, if possible
    if [ -e $PID_FILE ]
    then
      cat $PID_FILE | xargs kill > $LOG_FILE 2>&1
    fi
    # This *should* wait for all subprocesses to stop
    wait
    rm -f *.cookie
    rm -f *.tmp
    printf " done.\n\n"
  fi
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
  local MY_SECONDS_TARGET=$(( $SECONDS + $MY_DURATION ))
  # random temp/state files
  local RAND=`LC_CTYPE=C tr -dc A-Za-z0-9 < /dev/urandom | head -c 32 | xargs`
  local COOKIE="${RAND}.cookie"
  local TEMPFILE="${RAND}.tmp"
  local MY_CHECKOUT_SUCCESS=0
  local MY_CHECKOUT_ATTEMPTS=0
  local MY_ERROR_COUNT=0

  # Perform the actions for x many seconds
  # Note that if this loop is really long the rate of orders will be skewed
  while [ $SECONDS -le $MY_SECONDS_TARGET ]
  do
    local START=$SECONDS
    if $DEBUG
    then
      echo -e "------\nUser:${RAND}-${2}/${3}"
      echo "  iteration ends at: ${MY_SECONDS_TARGET}"
      echo "  time elapsed: ${SECONDS}"
      echo "  time to shop: ${MY_DURATION}"
      echo "  checkouts attempted: ${MY_CHECKOUT_ATTEMPTS}"
      echo "  checkouts successful: ${MY_CHECKOUT_SUCCESS}"
      echo "  error count: ${MY_ERROR_COUNT}"
    fi

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
    if $DEBUG
    then
      echo "User:${RAND}-${2}/${3} FORM_KEY: ${FORM_KEY}"
    fi

    curl -K $CURL_CONFIG_FILE -b $COOKIE -H $HTML_ACCEPT -c $COOKIE ${PROTO}://${HOST}/natural-science/science-history/simple-001196-product.html > $TEMPFILE 2>&1
    # find the cart URL
    CART_ACTION=$(find_cart_url $TEMPFILE)
    if $DEBUG
    then
      echo "User:${RAND}-${2}/${3} CART_ACTION: product 1 ${CART_ACTION}"
    fi
    sleep $PAGE_SLEEP
    # add to cart
    if $DEBUG
    then
      echo "User:${RAND}-${2}/${3} ADD: product 1 to cart"
    fi
    curl -K $CURL_CONFIG_FILE -b $COOKIE -c $COOKIE --retry $RETRY_COUNT -H $AJAX_ACCEPT -d "form_key=${FORM_KEY}&product=1196&related_product=&qty=${QTY}" ${CART_ACTION} > /dev/null 2>&1
    # cart page
    load_url $COOKIE "${CART_URL}" > /dev/null 2>&1
    # home page
    load_url $COOKIE "${PROTO}://${HOST}/" > /dev/null 2>&1
    sleep $PAGE_SLEEP
    
    ## PRODUCT 2
    ######

    # category
    load_url $COOKIE "${PROTO}://${HOST}/philosophy/eastern-philosophy.html" > /dev/null 2>&1
    # PDP; special promo price!
    load_url $COOKIE "${PROTO}://${HOST}/philosophy/eastern-philosophy/simple-002327-product.html" > $TEMPFILE 2>&1
    # find the cart URL
    CART_ACTION=$(find_cart_url $TEMPFILE)
    if $DEBUG
    then
      echo "User:${RAND}-${2}/${3} CART_ACTION: product 2 ${CART_ACTION}"
    fi
    sleep $PAGE_SLEEP

    # add to cart
    if $DEBUG
    then
      echo "User:${RAND}-${2}/${3} ADD: product 2 to cart"
    fi
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
    if $DEBUG
    then
      echo "User:${RAND}-${2}/${3} CART_ACTION: product 3 ${CART_ACTION}"
    fi
    sleep $PAGE_SLEEP
    
    # add to cart
    if $DEBUG
    then
      echo "User:${RAND}-${2}/${3} ADD: product 3 to cart"
    fi
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
    if $DEBUG
    then
      echo "User:${RAND}-${2}/${3} CART_ACTION: product 4 ${CART_ACTION}"
    fi
    sleep $PAGE_SLEEP
    
    # add to cart
    if $DEBUG
    then
      echo "User:${RAND}-${2}/${3} ADD: product 4 to cart"
    fi
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
    if $DEBUG
    then
      echo "User:${RAND}-${2}/${3} CART_ACTION: product 5 ${CART_ACTION}"
    fi
    sleep $PAGE_SLEEP
    
    # add to cart
    if $DEBUG
    then
      echo "User:${RAND}-${2}/${3} ADD: product 5 to cart"
    fi
    curl -K $CURL_CONFIG_FILE -b $COOKIE -c $COOKIE --retry $RETRY_COUNT -H $AJAX_ACCEPT -d "form_key=${FORM_KEY}&product=1522&related_product=&qty=${QTY}" ${CART_ACTION} > /dev/null 2>&1
    # cart page
    load_url $COOKIE "${CART_URL}" > /dev/null 2>&1
    sleep $PAGE_SLEEP

    ## CART, SHIPPING, TAX
    ######

    if $DEBUG
    then
      echo "User:${RAND}-${2}/${3} LOADING: cart"
    fi
    load_url $COOKIE "${CART_URL}" > /dev/null 2>&1
    sleep $CHECKOUT_SLEEP

    # NOTE: if you have shipping and tax features, test them here

    ## CHECKOUT
    ######
    
    MY_CHECKOUT_ATTEMPTS=$(( $MY_CHECKOUT_ATTEMPTS + 1 ))
    if $DEBUG
    then
      echo "User:${RAND}-${2}/${3} LOADING: checkout"
    fi

    load_url $COOKIE "${PROTO}://${HOST}/checkout/onepage/" > $TEMPFILE 2>&1
    # Find the address ID!
    # NOTE: not implemented for guest checkout
    ADDRESS_ID=`cat $TEMPFILE | grep 'address_id' | sed 's/[^0-9]*//g'`
    if $DEBUG
    then
      echo "User:${RAND}-${2}/${3} ADDRESS_ID: ${ADDRESS_ID}"
      echo "User:${RAND}-${2}/${3} SAVING: ${CHECKOUT_METHOD}"
    fi

    curl -K $CURL_CONFIG_FILE -b $COOKIE -c $COOKIE --retry $RETRY_COUNT -H $AJAX_ACCEPT -H $CHECKOUT_REFERER -H $AJAX_REQUESTED_WITH -d $CHECKOUT_METHOD ${PROTO}://${HOST}/checkout/onepage/saveMethod/ > /dev/null 2>&1

    # NOTE: this is where users could sign in or sign up
    if $DEBUG
    then
      echo "User:${RAND}-${2}/${3} LOADING: billing fields"
    fi

    load_ajax_checkout $COOKIE"${PROTO}://${HOST}/checkout/onepage/progress/?prevStep=billing" > /dev/null 2>&1
    sleep $CHECKOUT_SLEEP

    # Save billing
    if $DEBUG
    then
      echo "User:${RAND}-${2}/${3} SAVING: billing info"
    fi
    curl -K $CURL_CONFIG_FILE -b $COOKIE -c $COOKIE --retry $RETRY_COUNT -H $AJAX_ACCEPT -H $CHECKOUT_REFERER -H $AJAX_REQUESTED_WITH -d "billing[address_id]=&billing[firstname]=Test&billing[lastname]=Account&billing[company]=&billing[email]=test${RAND}@example.org&billing[street][]=411 SW 6th Ave&billing[street][]=&billing[city]=Portland&billing[region_id]=49&billing[region]=&billing[postcode]=97204&billing[country_id]=US&billing[telephone]=5035551212&billing[fax]=&billing[customer_password]=&billing[confirm_password]=&billing[save_in_address_book]=1&billing[use_for_shipping]=1" ${PROTO}://${HOST}/checkout/onepage/saveBilling/ > /dev/null 2>&1

    # Get additional; this tends to trigger other Magento features like shipping estimates
    if $DEBUG
    then
      echo "User:${RAND}-${2}/${3} LOADING: additional fields"
    fi
    curl -K $CURL_CONFIG_FILE -b $COOKIE -c $COOKIE --retry $RETRY_COUNT -H $AJAX_ACCEPT -H $CHECKOUT_REFERER -H $AJAX_REQUESTED_WITH -X POST ${PROTO}://${HOST}/checkout/onepage/getAdditional/ > $TEMPFILE 2>&1
    # Find the gift options ID
    GIFT_OPTION_LINES=`grep -F 'giftoptions' $TEMPFILE`
    # Ensure each input is separated by newline
    echo $GIFT_OPTION_LINES | sed "s/\/> ?</\/>\n</g" > $TEMPFILE
    # NOTE: the vanilla template has one gift option for the cart and each item
    GIFT_OPTION_ID_1=`sed 's/[^0-9]*//g' $TEMPFILE | head -n 1 | tail -n 1`
    GIFT_OPTION_ID_2=`sed 's/[^0-9]*//g' $TEMPFILE | head -n 2 | tail -n 1`
    GIFT_OPTION_ID_3=`sed 's/[^0-9]*//g' $TEMPFILE | head -n 3 | tail -n 1`
    GIFT_OPTION_ID_4=`sed 's/[^0-9]*//g' $TEMPFILE | head -n 4 | tail -n 1`
    GIFT_OPTION_ID_5=`sed 's/[^0-9]*//g' $TEMPFILE | head -n 5 | tail -n 1`
    GIFT_OPTION_ID_6=`sed 's/[^0-9]*//g' $TEMPFILE | head -n 6 | tail -n 1`
    if $DEBUG
    then
      echo "User:${RAND}-${2}/${3} Gift options:\n$(cat $TEMPFILE)"
      echo "User:${RAND}-${2}/${3} GIFT_OPTION_ID_1: ${GIFT_OPTION_ID_1}"
    fi
    sleep $PAGE_SLEEP
    if $DEBUG
    then
      echo "User:${RAND}-${2}/${3} LOADING: billing progress"
    fi
    
    # load the progress steps
    load_ajax_checkout $COOKIE "${PROTO}://${HOST}/checkout/onepage/progress/?prevStep=billing" > /dev/null 2>&1
    sleep $PAGE_SLEEP
    if $DEBUG
    then
      echo "User:${RAND}-${2}/${3} LOADING: shipping progress"
    fi
    load_ajax_checkout $COOKIE "${PROTO}://${HOST}/checkout/onepage/progress/?prevStep=shipping" > /dev/null 2>&1
    sleep $CHECKOUT_SLEEP

    # Save shipping
    if $DEBUG
    then
      echo "User:${RAND}-${2}/${3} SAVING: ${SHIPPING_METHOD}"
    fi
    curl -K $CURL_CONFIG_FILE -b $COOKIE -c $COOKIE --retry $RETRY_COUNT -H $CHECKOUT_REFERER -H $AJAX_ACCEPT -H $AJAX_REQUESTED_WITH -H $POST_CONTENT_TYPE -d $SHIPPING_METHOD ${PROTO}://${HOST}/checkout/onepage/saveShippingMethod/ > /dev/null 2>&1
    sleep $PAGE_SLEEP

    # load the progress steps
    if $DEBUG
    then
      echo "User:${RAND}-${2}/${3} LOADING: shipping progress"
    fi
    load_ajax_checkout $COOKIE "${PROTO}://${HOST}/checkout/onepage/progress/?prevStep=shipping_method" > /dev/null 2>&1
    sleep $CHECKOUT_SLEEP

    # Save payment
    if $DEBUG
    then
      echo "User:${RAND}-${2}/${3} SAVING: ${PAYMENT_METHOD}"
    fi
    curl -K $CURL_CONFIG_FILE -b $COOKIE -c $COOKIE --retry $RETRY_COUNT -H $AJAX_ACCEPT -H $CHECKOUT_REFERER -H $AJAX_REQUESTED_WITH -d $PAYMENT_METHOD ${PROTO}://${HOST}/checkout/onepage/savePayment/ > /dev/null 2>&1
    sleep $PAGE_SLEEP

    # load the progress steps
    load_ajax_checkout $COOKIE "${PROTO}://${HOST}/checkout/onepage/progress/?prevStep=payment" > /dev/null 2>&1
    if $DEBUG
    then
      echo "User:${RAND}-${2}/${3} LOADING: payment progress"
    fi
    sleep $CHECKOUT_SLEEP

    # Save order
    echo '' > $TEMPFILE
    curl -K $CURL_CONFIG_FILE -i -b $COOKIE -c $COOKIE --retry $RETRY_COUNT -H $AJAX_ACCEPT -H $CHECKOUT_REFERER -H $AJAX_REQUESTED_WITH -d $PAYMENT_METHOD ${PROTO}://${HOST}/checkout/onepage/saveOrder/form_key/${FORM_KEY}/ > $TEMPFILE
    if $DEBUG
    then
      echo "User:${RAND}-${2}/${3} SAVING: order"
    fi
    success_count=$(grep -F '{"success":true,"error":false}' $TEMPFILE | wc -l)
    if [ $success_count -gt 0 ]
    then
      if $DEBUG
      then
        echo "User:${RAND}-${2}/${3} SUCCESS!"
      fi
      MY_CHECKOUT_SUCCESS=$(( $MY_CHECKOUT_SUCCESS + 1 ))
    else
      if $DEBUG
      then
        echo "User:${RAND}-${2}/${3} ERROR: checkout not successful"
      fi
      MY_ERROR_COUNT=$(( $MY_ERROR_COUNT + 1 ))
    fi
    sleep $CHECKOUT_SLEEP

    # Load reciept
    if $DEBUG
    then
      echo "User:${RAND}-${2}/${3} LOADING: reciept"
    fi
    load_url $COOKIE "${PROTO}://${HOST}/checkout/onepage/success/" > /dev/null 2>&1
    sleep $CHECKOUT_SLEEP

    # abandon this session
    rm -f $COOKIE
    rm -f $TEMPFILE

    ELAPSED_TIME=$(( $SECONDS - $START ))

    if $DEBUG
    then
      message="\n\n------\nUser:${RAND}-${2}/${3} CHECKOUT COMPLETED (in ${ELAPSED_TIME} seconds)\n------\n\n"
      echo -e $message >> $LOG_FILE
      echo -e $message
    fi
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

# concurrency notes: http://opennomad.com/content/parallelism-or-multiple-threads-bash
for c in "${CONCURRENCIES[@]}"
do
  echo "Shopping as ${c} users for ${CONCURRENCY_DURATION} seconds."
  date
  echo "START: checkout as ${c} users (`date`)" >> $LOG_FILE
  # reset instance counter
  i=1

  # create the pid file
  touch $PID_FILE
  if [ $? != 0 ];
  then
    echo "FATAL: could not write to pid file: ${PID_FILE}"
    exit 1
  fi
  # clear the pids
  echo '' > $PID_FILE

  START_TIME=$SECONDS
  # perform the actions for x many users
  while [ $i -le $c ]
  do
    ELAPSED_TIME=$(( $SECONDS - $START_TIME ))
    # fork a process to shop
    TIME_TO_RUN=$(( $CONCURRENCY_DURATION - $ELAPSED_TIME ))
    timed_shop $TIME_TO_RUN $i $c &
    SUBPID=$!
    echo $SUBPID >> $PID_FILE
    if $DEBUG
    then
      echo "Forking PID ${SUBPID}"
    fi
    # increment instance counter
    i=$(( $i + 1 ))
    if $DEBUG
    then
      echo "Pausing for ${INTRA_USER_SLEEP} seconds"
    fi
    # wait for the configured time period
    sleep $INTRA_USER_SLEEP
  done
  if $DEBUG
  then
    echo -e "All simulated users forked; waiting for them to complete…\n"
  fi
  # wait for the forked processes to complete
  wait
  message="END: checkout as ${c} users (`date`)"
  echo $message >> $LOG_FILE
  echo -e "${message}\n"
  rm -f $PID_FILE
done

echo -e "Done! All concurrency scenarios have run.\n"
exit 0
