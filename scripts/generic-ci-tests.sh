#!/usr/bin/env bash
set -e

###############################################################################
#
#   generic-ci-tests.sh
#
#   Execute all tests for edx-platform.
#
#   This script can be called from CI jobs that define
#   these environment variables:
#
#   `TEST_SUITE` defines which kind of test to run.
#   Possible values are:
#
#       - "quality": Run the quality (pep8/pylint) checks
#       - "lms-unit": Run the LMS Python unit tests
#       - "cms-unit": Run the CMS Python unit tests
#       - "js-unit": Run the JavaScript tests
#       - "commonlib-unit": Run Python unit tests from the common/lib directory
#       - "commonlib-js-unit": Run the JavaScript tests and the Python unit
#           tests from the common/lib directory
#       - "lms-acceptance": Run the acceptance (Selenium/Lettuce) tests for
#           the LMS
#       - "cms-acceptance": Run the acceptance (Selenium/Lettuce) tests for
#           Studio
#       - "bok-choy": Run acceptance tests that use the bok-choy framework
#
#   `SHARD` is a number indicating which subset of the tests to build.
#
#       For "bok-choy" and "lms-unit", the tests are put into shard groups
#       using the 'attr' decorator (e.g. "@attr(shard=1)"). Anything with
#       the 'shard=n' attribute will run in the nth shard. If there isn't a
#       shard explicitly assigned, the test will run in the last shard.
#
#   Jenkins-specific configuration details:
#
#   - The edx-platform git repository is checked out by the Jenkins git plugin.
#   - Jenkins logs in as user "jenkins"
#   - The Jenkins file system root is "/home/jenkins"
#   - An init script creates a virtualenv at "/home/jenkins/edx-venv"
#     with some requirements pre-installed (such as scipy)
#
#  Jenkins worker setup:
#  See the edx/configuration repo for Jenkins worker provisioning scripts.
#  The provisioning scripts install requirements that this script depends on!
#
###############################################################################

# If the environment variable 'SHARD' is not set, default to 'all'.
# This could happen if you are trying to use this script from
# jenkins and do not define 'SHARD' in your multi-config project.
# Note that you will still need to pass a value for 'TEST_SUITE'
# or else no tests will be executed.
SHARD=${SHARD:="all"}
NUMBER_OF_BOKCHOY_THREADS=${NUMBER_OF_BOKCHOY_THREADS:=1}

# Clean up previous builds
git clean -qxfd

function emptyxunit {

    cat > reports/$1.xml <<END
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="$1" tests="1" errors="0" failures="0" skip="0">
<testcase classname="$1" name="$1" time="0.604"></testcase>
</testsuite>
END

}

if [[ $DJANGO_VERSION == '1.11' ]]; then
    TOX="tox -e py27-django111 --"
elif [[ $DJANGO_VERSION == '1.10' ]]; then
    TOX="tox -e py27-django110 --"
elif [[ $DJANGO_VERSION == '1.9' ]]; then
    TOX="tox -e py27-django19 --"
else
    TOX=""
fi
PAVER_ARGS="-v"
PARALLEL="--processes=-1"
export SUBSET_JOB=$JOB_NAME

function run_paver_quality {
    QUALITY_TASK=$1
    shift
    mkdir -p test_root/log/
    LOG_PREFIX=test_root/log/$QUALITY_TASK
    $TOX paver $QUALITY_TASK $* 2> $LOG_PREFIX.err.log > $LOG_PREFIX.out.log || {
        echo "STDOUT (last 100 lines of $LOG_PREFIX.out.log):";
        tail -n 100 $LOG_PREFIX.out.log;
        echo "STDERR (last 100 lines of $LOG_PREFIX.err.log):";
        tail -n 100 $LOG_PREFIX.err.log;
        return 1;
    }
    return 0;
}

case "$TEST_SUITE" in

    "quality")
        echo "Finding fixme's and storing report..."
        run_paver_quality find_fixme || EXIT=1
        echo "Finding pep8 violations and storing report..."
        run_paver_quality run_pep8 || EXIT=1
        echo "Finding pylint violations and storing in report..."
        run_paver_quality run_pylint -l $LOWER_PYLINT_THRESHOLD:$UPPER_PYLINT_THRESHOLD || EXIT=1

        mkdir -p reports

        echo "Finding ESLint violations and storing report..."
        run_paver_quality run_eslint -l $ESLINT_THRESHOLD || EXIT=1
        echo "Finding Stylelint violations and storing report..."
        run_paver_quality run_stylelint -l $STYLELINT_THRESHOLD || EXIT=1
        echo "Running code complexity report (python)."
        run_paver_quality run_complexity || echo "Unable to calculate code complexity. Ignoring error."
        echo "Running xss linter report."
        run_paver_quality run_xsslint -t $XSSLINT_THRESHOLDS || EXIT=1
        echo "Running safe commit linter report."
        run_paver_quality run_xsscommitlint || EXIT=1
        # Run quality task. Pass in the 'fail-under' percentage to diff-quality
        echo "Running diff quality."
        run_paver_quality run_quality -p 100 -l $LOWER_PYLINT_THRESHOLD:$UPPER_PYLINT_THRESHOLD || EXIT=1

        # Need to create an empty test result so the post-build
        # action doesn't fail the build.
        emptyxunit "quality"
        exit $EXIT
        ;;

    "lms-unit")
        case "$SHARD" in
            "all")
                $TOX paver test_system -s lms --disable_capture $PAVER_ARGS $PARALLEL 2> lms-tests.log
                ;;
            [1-3])
                $TOX paver test_system -s lms --disable_capture --eval-attr="shard==$SHARD" $PAVER_ARGS $PARALLEL 2> lms-tests.$SHARD.log
                ;;
            4|"noshard")
                $TOX paver test_system -s lms --disable_capture --eval-attr='not shard' $PAVER_ARGS $PARALLEL 2> lms-tests.4.log
                ;;
            *)
                # If no shard is specified, rather than running all tests, create an empty xunit file. This is a
                # backwards compatibility feature. If a new shard (e.g., shard n) is introduced in the build
                # system, but the tests are called with the old code, then builds will not fail because the
                # code is out of date. Instead, there will be an instantly-passing shard.
                mkdir -p reports/lms
                emptyxunit "lms/nosetests"
                ;;
        esac
        ;;

    "cms-unit")
        $TOX paver test_system -s cms --disable_capture $PAVER_ARGS 2> cms-tests.log
        ;;

    "commonlib-unit")
        $TOX paver test_lib --disable_capture $PAVER_ARGS 2> common-tests.log
        ;;

    "js-unit")
        $TOX paver test_js --coverage
        $TOX paver diff_coverage
        ;;

    "commonlib-js-unit")
        $TOX paver test_js --coverage --skip-clean || { EXIT=1; }
        paver test_lib --skip-clean $PAVER_ARGS || { EXIT=1; }

        # This is to ensure that the build status of the shard is properly set.
        # Because we are running two paver commands in a row, we need to capture
        # their return codes in order to exit with a non-zero code if either of
        # them fail. We put the || clause there because otherwise, when a paver
        # command fails, this entire script will exit, and not run the second
        # paver command in this case statement. So instead of exiting, the value
        # of a variable named EXIT will be set to 1 if either of the paver
        # commands fail. We then use this variable's value as our exit code.
        # Note that by default the value of this variable EXIT is not set, so if
        # neither command fails then the exit command resolves to simply exit
        # which is considered successful.
        exit $EXIT
        ;;

    "lms-acceptance")
        $TOX paver test_acceptance -s lms -vvv --with-xunit
        ;;

    "cms-acceptance")
        $TOX paver test_acceptance -s cms -vvv --with-xunit
        ;;

    "bok-choy")

        PAVER_ARGS="-n $NUMBER_OF_BOKCHOY_THREADS"

        case "$SHARD" in

            "all")
                $TOX paver test_bokchoy $PAVER_ARGS
                ;;

            [1-9]|10)
                $TOX paver test_bokchoy --eval-attr="shard==$SHARD" $PAVER_ARGS
                ;;

            11|"noshard")
                $TOX paver test_bokchoy --eval-attr='not shard and not a11y' $PAVER_ARGS
                ;;

            # Default case because if we later define another bok-choy shard on Jenkins
            # (e.g. Shard 10) in the multi-config project and expand this file
            # with an additional case condition, old branches without that commit
            # would not execute any tests on the worker assigned to that shard
            # and thus their build would fail.
            # This way they will just report 1 test executed and passed.
            *)
                # Need to create an empty test result so the post-build
                # action doesn't fail the build.
                # May be unnecessary if we changed the "Skip if there are no test files"
                # option to True in the jenkins job definitions.
                mkdir -p reports/bok_choy
                emptyxunit "bok_choy/xunit"
                ;;
        esac
        ;;
esac
