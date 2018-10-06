#!/bin/bash

# by mmone with contribution by jhol, tssva
# on github at https://github.com/mmone/marlintool

set -e

# The default config file to look for
defaultParametersFile="marlintool.params"

cacheDir=$PWD/.cache

scriptName=$0

l=2
status_out=/dev/null

## Checks that the tools listed in arguments are all installed.
checkTools()
{
  for cmd in "$@"; do
    command -v $cmd >/dev/null || {
      >&2 echo "The following tools must be installed:"
      >&2 echo "  $@"
      >&2 echo "  Failed to find $cmd"
      >&2 echo
      exit 1
    }
  done
}

checkCurlWget()
{
  if ! curl=$(command -v curl) && ! wget=$(command -v wget); then
    >&2 echo "Neither curl nor wget were found installed"
    >&2 echo
    exit 1
  fi
}

gitRepoName()
{
  basename "$1" ".${1##*.}"
}

getFile()
{
  local url=$1
  local file=$2
  local cacheFile=$cacheDir/$file

  if [ ! -f $cacheFile ]; then
    >&$l echo "  Downloading from $url..."

    local downloadTmpFile=$tmpDir/download
    if [ "$curl" != "" ]; then
      $curl -o "$downloadTmpFile" "$url"
    else
      $wget -O "$downloadTmpFile" "$url"
    fi

    mkdir -p $cacheDir
    mv $downloadTmpFile $cacheFile
  else
    >&$l echo "  Retrieving $(basename $file) from cache..."
  fi

  echo $cacheFile
}

getGitRepo()
{
  local url=$1
  local branch=$2

  local repoName=$(gitRepoName $url)
  local repoDir=$tmpDir/$repoName
  local cacheRepo=$cacheDir/$repoName

  >&2 echo "  Getting $repoName..."
  if [ -d $cacheRepo ]; then
    >&$l echo "    Updating repository from $url..."
    (cd $cacheRepo; git fetch -p origin 2>$status_out)
  else
    >&$l echo "    Cloning repository from $repoDir..."
    git clone --bare $url $cacheRepo 2>$status_out
  fi

  >&2 echo "    Copying from cache..."
  if [ "$marlinRepositoryBranch" != "" ]; then
    git clone -b "$branch" --single-branch $cacheRepo $repoDir 2>$status_out
  else
    git clone $cacheRepo $repoDir 2>$status_out
  fi

  echo $repoDir
}

unpackArchive()
{
  local archive=$1
  local dir=$2

  case $archive in
    *.zip)
      unzip -q "$archive" -d "$dir" >$status_out
      ;;
    *.tar.*)
      tar -xf "$archive" -C "$dir" --strip 1 >$status_out
      ;;
  esac
}

## Download the toolchain and unpack it
getArduinoToolchain()
{
  >&$l echo -e "\nGetting Arduino environment..."

  local archive=$(getFile http://downloads-02.arduino.cc/"$arduinoToolchainArchive" $arduinoToolchainArchive)
  rm -rf "$arduinoDir"
  mkdir -p "$arduinoDir/portable"
  >&$l echo "  Unpacking (this might take a while)..."
  if [ "$os" == "Darwin" ]; then
    unzip -q "$archive" -d "$arduinoDir"
  else
    tar -xf "$archive" -C "$arduinoDir" --strip 1
  fi
}


## Get dependencies and move them in place
getDependencies()
{
  >&$l echo -e "\nGetting libraries..."

  for library in ${marlinDependencies[@]}; do
    local libName=
    local libUrl=
    local libDir=

    IFS=',' read libName libUrl libDir <<< "$library"
    local libRepo=$(getGitRepo "$libUrl" "")
    mv -f "$libRepo/$libDir" "$arduinoLibrariesDir/$libName"
    rm -rf "$libRepo"
  done
}

## Clone Marlin
getMarlin()
{
  >&$l echo -e "\nGetting Marlin..."
  local repoDir=$(getGitRepo "$marlinRepositoryUrl" "$marlinRepositoryBranch")
  mv "$repoDir" "$marlinDir"
  exit
}

## Update an existing Marlin clone
checkoutMarlin()
{
  date=`date +%Y-%m-%d-%H-%M-%S`

  # backup configuration
  backupMarlinConfiguration $date

  cd $marlinDir

  >&$l echo -e "\nFetching most recent Marlin from \"$marlinRepositoryUrl\" ...\n"

  git fetch >$status_out
  git checkout >$status_out
  git reset origin/`git rev-parse --abbrev-ref HEAD` --hard >$status_out

  >&$l echo -e "\n"

  cd ..

  restoreMarlinConfiguration $date
  exit
}


## Get the toolchain and Marlin, install board definition
setupEnvironment()
{
  >&$l echo -e "\nSetting up build environment in \"$arduinoDir\" ...\n"
  getArduinoToolchain
  getDependencies
  getHardwareDefinition
  exit
}

## Fetch and install anet board hardware definition
getHardwareDefinition()
{
  if [ "$hardwareDefinitionRepo" != "" ]; then
    >&$l echo -e "\nGetting board hardware definition..."
    local repoPath=$(getGitRepo "$hardwareDefinitionRepo" "")

    >&$l echo "  Moving board hardware definition into arduino directory..."

    mv -f $repoPath/hardware/* "$arduinoHardwareDir"
    rm -rf $repoPath
  fi
}


## Backup Marlin configuration
## param #1 backup name
backupMarlinConfiguration()
{
  >&$l echo -e "\nSaving Marlin configuration\n"
  >&$l echo -e "  \"Configuration.h\""
  >&$l echo -e "  \"Configuration_adv.h\""
  >&$l echo -e "\nto \"./configuration/$1/\"\n"

  mkdir -p configuration/$1

  cp "$marlinDir"/Marlin/Configuration.h configuration/"$1"
  cp "$marlinDir"/Marlin/Configuration_adv.h configuration/"$1"
}

## Restore Marlin Configuration from backup
## param #1 backup name
restoreMarlinConfiguration()
{
  if [ -d "configuration/$1" ]; then
    >&$l echo -e "Restoring Marlin configuration\n"
    >&$l echo -e "  \"Configuration.h\""
    >&$l echo -e "  \"Configuration_adv.h\""
    >&$l echo -e "\nfrom \"./configuration/$1/\"\n"

    cp configuration/"$1"/Configuration.h "$marlinDir"/Marlin/
    cp configuration/"$1"/Configuration_adv.h "$marlinDir"/Marlin/
  else
    echo -e "\nBackup configuration/$1 not found!\n"
  fi
  exit
}

## Build Marlin
verifyBuild()
{
  >&$l echo -e "\nVerifying build ...\n"

  "$arduinoExecutable" --verify --verbose --board "$boardString" "$marlinDir"/Marlin/Marlin.ino --pref build.path="$buildDir"
  exit
}


## Build Marlin and upload 
buildAndUpload()
{
  >&$l echo -e "\nBuilding and uploading Marlin build from \"$buildDir\" ...\n"

  "$arduinoExecutable" --upload --port "$port" --verbose --board "$boardString" "$marlinDir"/Marlin/Marlin.ino --pref build.path="$buildDir"
  exit
}


## Delete everything that was downloaded
cleanEverything()
{
  rm -Rf "$arduinoDir"
  rm -Rf "$marlinDir"
  rm -Rf "$buildDir"
}

## Delete everything that was downloaded
cleanCache()
{
  rm -Rf "$cacheDir"
}

## Print help
printUsage()
{
  echo "Usage:"
  echo " $scriptName ARGS"
  echo
  echo "Builds an installs Marlin 3D printer firmware."
  echo
  echo "Options:"
  echo
  echo " -s, --setup                 Download and configure the toolchain and the"
  echo "                             necessary libraries for building Marlin."
  echo " -m, --marlin                Download Marlin sources."
  echo " -f, --fetch                 Update an existing Marlin clone."
  echo " -v, --verify                Build without uploading."
  echo " -u, --upload                Build and upload Marlin."
  echo " -b, --backupConfig  [name]  Backup the Marlin configuration to the named backup."
  echo " -r, --restoreConfig [name]  Restore the given configuration into the Marlin directory."
  echo "                               Rename to Configuration.h implicitly."
  echo " -c, --clean                 Cleanup everything. Remove Marlin sources and Arduino toolchain"
  echo " -C, --clean-cache           Clean up the download cache."
  echo " -p, --port [port]           Set the serialport for uploading the firmware."
  echo "                               Overrides the default in the script."
  echo " -q, --quiet                 Don't print status messages."
  echo " -v, --verbose               Print the output of sub-processes."
  echo " -h, --help                  Show this doc."
  echo
  exit
}

onExit()
{
  rm -rf $tmpDir
}

# Check for parameters file and source it if available

if [ -f $defaultParametersFile ]; then
  source "$defaultParametersFile"
else
  echo -e "\n ==================================================================="
  echo -e "\n  Can't find $defaultParametersFile!"
  echo -e "\n  Please rename the \"$defaultParametersFile.example\" file placed in the"
  echo -e "  same directory as this script to \"$defaultParametersFile\" and edit"
  echo -e "  if neccessary.\n"
  echo -e " ===================================================================\n\n"
  exit 1
fi

# Temporary directory
tmpDir=$(mktemp -d "${TMPDIR:-/tmp}/marlintool.XXXXXX")
trap "onExit" EXIT

# Toolchain architecture
arch=$(uname -m)
case $arch in
  arm*) arduinoToolchainArchitecture="linuxarm" ;;
  i386|i486|i586|i686) arduinoToolchainArchitecture="linux32" ;;
  x86_64) arduinoToolchainArchitecture="linux64" ;;
  *)
    >&2 echo "Unsuppored platform architecture: $arch"
    exit 1
    ;;
esac

# Operating system specific values
os=$(uname -s)
if [ "$os" == "Darwin" ]; then
  arduinoToolchainArchive="arduino-$arduinoToolchainVersion-macosx.zip"
  arduinoExecutable="$arduinoDir/Arduino.app/Contents/MacOS/Arduino"
  arduinoHardwareDir="$arduinoDir/Arduino.app/Contents/Java/hardware"
  arduinoLibrariesDir="$arduinoDir/Arduino.app/Contents/Java/libraries"
else
  arduinoToolchainArchive="arduino-$arduinoToolchainVersion-$arduinoToolchainArchitecture.tar.xz"
  arduinoExecutable="$arduinoDir/arduino"
  arduinoHardwareDir="$arduinoDir/hardware"
  arduinoLibrariesDir="$arduinoDir/libraries"
fi


checkTools git tar unzip
checkCurlWget

if [ "$1" = "" ]; then
  printUsage >&2
  exit 1
fi

while [ "$1" != "" ]; do
  case $1 in
    -p | --port )
      shift
      port=$1
      ;;
    -s | --setup )
      setupEnvironment
      ;;
    -m | --marlin )
      getMarlin
      ;;
    -f | --fetch )
      checkoutMarlin
      ;;
    -v | --verify )
      verifyBuild
      ;;
    -u | --upload )
      buildAndUpload
      ;;
    -b | --backupConfig )
      shift
      backupMarlinConfiguration $1 exit
      ;;
    -r | --restoreConfig )
      shift
      restoreMarlinConfiguration $1
      ;;
    -c | --clean )
      shift
      cleanEverything
      ;;
    -C | --clean-cache )
      shift
      cleanCache
    -q | --quiet )
      l=/dev/null
      shift
      ;;
    -v | --verbose )
      status_out=1
      shift
      ;;
    -h | --help )
      printUsage
      ;;
    * )
      printUsage >&2
      exit 1
  esac
  shift
done
