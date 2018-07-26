#!/bin/bash

###
# This script requires a config file to be specified that contains a listing of 
# of git repos to download.  Each line can consist of the following 
# format: <git repo URL>
# Ex: https://github.com/afcyber-dream/bashellite.git - This will either clone or pull the latest changes from that git repo.
#     https://github.com/afcyber-dream/bashellite - This is another way of specifying the previous line.
###
# Example conf file:
###
# https://github.com/afcyber-dream/bashellite.git
# https://github.com/afcyber-dream/bashellite-configs
###

### Program Version:
    script_version="0.1.0-beta"

# Sets timestamp used in log file lines and log file names and other functions
Get_time() {
  timestamp="$(date --iso-8601='ns' 2>/dev/null)";
  timestamp="${timestamp//[^0-9]}";
  timestamp="${timestamp:8:8}";
  if [[ -z "${timestamp}" ]]; then
    echo "[FAIL] Failed to set timestamp; ensure date supports \"--iso-8601\" flag!";
    exit 1;
  fi
}

# This function does a dependency check before proceeding
Check_deps() {
  which which &>/dev/null \
    || { echo "[FAIL] Dependency (which) missing!"; exit 1; };
  for dep in grep \
             date \
             tput \
             basename \
             realpath \
             dirname \
             ls \
             mkdir \
             chown \
             touch \
             cat \
             sed \
             ln \
             tee \
             git;
  do
    which ${dep} &>/dev/null \
      || { echo "[FAIL] Dependency (${dep}) missing!"; exit 1; };
  done
}

# Ensures that the versions of certain deps are the GNU version before proceeding
Ensure_gnu_deps() {
  for dep in grep \
             date \
             basename \
             realpath \
             dirname \
             ls \
             mkdir \
             chown \
             touch \
             cat \
             sed \
             ln \
             tee;
  do
    grep "GNU" <<<"$(${dep} --version 2>&1)" &>/dev/null \
      || { echo "[FAIL] Dependency (${dep}) not GNU version!"; exit 1; };
  done
}

# These functions are used to generate colored output
#  Info is green, Warn is yellow, Fail is red.
Set_colors() {
  mkclr="$(tput sgr0)";
  mkwht="$(tput setaf 7)";
  mkgrn="$(tput setaf 2)";
  mkylw="$(tput setaf 3)";
  mkred="$(tput setaf 1)";
}

Info() {
  Get_time;
  if [[ ${dryrun} ]]; then
    echo -e "${mkwht}${timestamp} ${mkgrn}[DRYRUN|INFO] $*${mkclr}";
  else
    echo -e "${mkwht}${timestamp} ${mkgrn}[INFO] $*${mkclr}";
  fi
}

Warn() {
  Get_time;
  if [[ ${dryrun} ]]; then
    echo -e "${mkwht}${timestamp} ${mkylw}[DRYRUN|WARN] $*${mkclr}" >&2;
  else
    echo -e "${mkwht}${timestamp} ${mkylw}[WARN] $*${mkclr}" >&2;
  fi
}

Fail() {
  Get_time;
  if [[ ${dryrun} ]]; then
    echo -e "${mkwht}${timestamp} ${mkred}[DRYRUN|FAIL] $*${mkclr}" >&2;
  else
    echo -e "${mkwht}${timestamp} ${mkred}[FAIL] $*${mkclr}" >&2;
  fi
  exit 1;
}

# This function prints usage messaging to STDOUT when invoked.
Usage() {
  echo
  echo "Usage: $(basename ${0}) v${script_version}"
  echo "       [-m mirror_top-level_directory]"
  echo "       [-h]"
  #echo "       [-d]"
  echo "       [-r repository_name]"
  echo
  echo
  echo "       Required Parameter(s):"
  echo "       -m:  Sets a temporary disk mirror top-level directory."
  echo "            Only absolute (full) paths are accepted!"
  echo "       -r:  The repo name to sync."
  echo "       -c:  The config file that has the filter of images to download"
  echo "       Optional Parameter(s):"
  echo "       -h:  Prints this usage message."
  #echo "       -d:  Dry-run mode. Pulls down a listing of the files and"
  #echo "            directories it would download, and then exits."
  #echo "       -s:  An optional site name to pull images from.  Default is: index.docker.io"
}

# This function parses the parameters passed over the command-line by the user.
Parse_parameters() {
  if [[ "${#}" = "0" ]]; then
    Usage;
    Fail "\n${0} has mandatory parameters; review usage message and try again.\n";
  fi

  # This section unsets some variables, just in case.
  unset mirror_tld;
  unset repo_name;
  #unset dryrun;
  unset config_file;
  #unset site_name;

  mirror_tld=$(pwd)
  #site_name="index.docker.io"

  # Bash-builtin getopts is used to perform parsing, so no long options are used.
  while getopts ":m:r:c:h" passed_parameter; do
   case "${passed_parameter}" in
      m)
        mirror_tld="${OPTARG}";
        ;;
      r)
        # Sanitizes the directory name of spaces or any other undesired characters.
	      repo_name="${OPTARG//[^a-zA-Z1-9_-]}";
	      ;;
      #d)
      #  dryrun=true;
      #  ;;
      c)
        config_file="${OPTARG}";
        ;;
      #s)
      #  site_name="${OPTARG}";
      #  ;;
      h)
        Usage;
        exit 0;
        ;;
      *)
        Usage;
        Fail "\nInvalid option passed to \"$(basename ${0})\"; exiting. See Usage below.\n";
        ;;
    esac
  done
  shift $((OPTIND-1));
}

#################################
#
### This section is for functions related to the main execution of the program.
### Functions in this section perform the following tasks:
###   - Check to ensure EUID is 0 before attempting sync
###   - Ensure all required parameters are set before attempting sync
###   - Ensuring appropriate directories exist for mirror
###   - Ensuring appropriate dirs/files exist per repo
###   - Ensuring repo metadata is populated before attempting sync
###   - Ensuring required sync providers are installed and accesssible
###   - Performing the sync
###   - Reporting on the success of the sync
#
################################################################################

Validate_variables() {

  # This santizes the directory name of spaces or any other undesired characters.
  mirror_tld="${mirror_tld//[^a-zA-Z1-9_-/]}";
  mirror_tld=${mirror_tld//\"};
  if [[ "${mirror_tld:0:1}" != "/" ]]; then
    Usage;
    Fail "\nAbsolute paths only, please; exiting.\n";
  else
    # Drops the last "/" from the value of mirror_tld to ensure uniformity for functions using it.
    # Note: as a side-effect, this effective prevents using just "/" as the value for mirror_tld.
    mirror_tld="${mirror_tld%\/}";
  fi

  # Ensures repo_name_array is not empty
  #if [[ -z "${repo_name_array}" ]]; then
  #  Fail "Bashellite requires at least one valid repository.";
  #fi

  # If the mirror_tld is unset or null; then exit.
  # Since the last "/" was dropped in Parse_parameter,
  # If user passed "/" for mirror_tld value, it effectively becomes "" (null).
  if [[ -z "${mirror_tld}" ]]; then
    Usage;
    Fail "\nPlease set the desired location of the local mirror; exiting.\n";
  fi
}

# This function creates/validates the file/directory framework for the requested repo.
Validate_repo_framework() {
  if [[ -n "${repo_name}" ]]; then
    Info "Creating/validating directory and file structure for mirror and repo (${repo_name})...";
    #mkdir -p "${providers_tld}";
    mirror_repo_name="${repo_name//__/\/}";
    if [[ ! -d "${mirror_tld}" ]]; then
      Fail "Mirror top-level directory (${mirror_tld}) does not exist!"
    else
      mkdir -p "${mirror_tld}/${mirror_repo_name}/" &>/dev/null \
      || Fail "Unable to create directory (${mirror_tld}/${mirror_repo_name}); check permissions."
    fi
  fi
}

# This function performs the actual sync of the repository
Sync_repository() {
  for line in $(cat ${config_file}); do
    git_repo_name="${line##*/}"
    git_repo_dir_name="${git_repo_name//.git}"
    git_repo_url="${line}"

    if [[ -d "${mirror_tld}/${repo_name}/${git_repo_dir_name}" ]]; then
      Info "Pulling any updates from repo: ${git_repo_url}..."
      cd "${mirror_tld}/${repo_name}/${git_repo_dir_name}"
      git pull
    else
      Info "New repo detected, cloning repo: ${git_repo_url}..."
      cd "${mirror_tld}/${repo_name}"
      git clone "${git_repo_url}"
    fi
  done
}

################################################################################


################################################################################
### PROGRAM EXECUTION ###
#########################
### This section is for the execution of the previously defined functions.
################################################################################

# These complete prepatory admin tasks before executing the sync functions.
# These functions require minimal file permissions and avoid writes to disk.
# This makes errors unlikely, which is why verbose logging is not enabled for them.
Check_deps \
&& Ensure_gnu_deps \
&& Set_colors \
&& Parse_parameters ${@} \

# This for-loop executes the sync functions on the appropriate repos (either all or just one of them).
# Logging is enabled for all of these functions; some don't technically need to be in the loop, except for logging.
if [[ "${?}" == "0" ]]; then
  Info "Starting ${0} for repo (${repo_name})..."
  for task in \
              Validate_variables \
              Validate_repo_framework \
              Sync_repository;
  do
    ${task};
  done
else
  # This is ONLY executed if one of the prepatory/administrative functions fails.
  # Most of them handle their own errors, and exit on failure, but a few do not.
  echo "[FAIL] ${0} failed to execute requested tasks; exiting!";
  exit 1;
fi
################################################################################
