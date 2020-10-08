#!/usr/bin/env bash

# Copyright 2016 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Set PROGram name
PROG=${0##*/}
########################################################################
#+
#+ NAME
#+     $PROG - Push Kubernetes Release Artifacts up to GCS
#+
#+ SYNOPSIS
#+     $PROG  [--nomock] [--federation] [--noupdatelatest] [--ci]
#+            [--bucket=<GS bucket>]
#+            [--private-bucket]
#+     $PROG  [--helpshort|--usage|-?]
#+     $PROG  [--help|-man]
#+
#+ DESCRIPTION
#+     Replaces kubernetes/build/push-*-build.sh.
#+     Used for pushing developer builds and Jenkins' continuous builds.
#+
#+     Developer pushes simply run as they do pushing to devel/ on GCS.
#+     In --ci mode, $PROG runs in mock mode by default.  Use --nomock to do
#+     a real push.
#+
#+     Federation values are just passed through as exported global vars still
#+     due to the fact that we're still leveraging the existing federation
#+     interface in kubernetes proper.
#+
#+ OPTIONS
#+     [--nomock]                  - Enables a real push (--ci only)
#+     [--federation]              - Enable FEDERATION push
#+     [--ci]                      - Used when called from Jenkins (for ci
#+                                   runs)
#+     [--fast]                    - Specifies a fast build (linux amd64 only)
#+     [--extra-publish-file=]     - [DEPRECATED - use --extra-version-markers
#+                                   instead] Used when need to upload
#+                                   additional version file to GCS. The path
#+                                   is relative and is append to a GCS path.
#+                                   (--ci only)
#+     [--extra-version-markers=]  - Used when need to upload additional
#+                                   version markers to GCS. The path is
#+                                   relative and is append to a GCS path.
#+                                   (--ci only)
#+     [--bucket=]                 - Specify an alternate bucket for pushes
#+     [--release-type=]           - Override auto-detected release type
#+                                   (normally devel or ci)
#+     [--release-kind=]           - Kind of release to push to GCS. Supported
#+                                   values are kubernetes(default) or
#+                                   federation.
#+     [--gcs-suffix=]             - Specify a suffix to append to the upload
#+                                   destination on GCS.
#+     [--docker-registry=]        - If set, push docker images to specified
#+                                   registry/project
#+     [--version-suffix=]         - Append suffix to version name if set.
#+     [--noupdatelatest]          - Do not update the latest file
#+     [--private-bucket]          - Do not mark published bits on GCS as
#+                                   publicly readable.
#+     [--allow-dup]               - Do not exit error if the build already
#+                                   exists on the gcs path.
#+     [--help | -man]             - display man page for this script
#+     [--usage | -?]              - display in-line usage
#+
#+ EXAMPLES
#+     $PROG                     - Do a developer push
#+     $PROG --nomock --federation --ci
#+                               - Do a (non-mocked) CI push with federation
#+     $PROG --bucket=kubernetes-release-$USER
#+                               - Do a developer push to
#+                                 kubernetes-release-$USER
#+
#+ FILES
#+
#+ SEE ALSO
#+     common.sh                 - base function entry points
#+     releaselib.sh             - ::release:: namespace entry points
#+     kubernetes/hack/jenkins/build.sh
#+                               - caller
#+
#+ BUGS/TODO
#+     * Should federation be pulled into release repo?  It would offer more
#+       control.
#+
########################################################################
# If NO ARGUMENTS should return *usage*, uncomment the following line:
#usage=${1:-yes}

if [[ $(uname) == "Darwin" ]]; then
  READLINK_CMD=greadlink
else
  READLINK_CMD=readlink
fi

source $(dirname $($READLINK_CMD -ne $BASH_SOURCE))/lib/common.sh
source $TOOL_LIB_PATH/gitlib.sh
source $TOOL_LIB_PATH/releaselib.sh

###############################################################################
# Creates a tarball for upload to a GCS staging directory.
# @param gcs_stage - the staging directory
# @param source and destination arguments
# @return 1 if tar directory or tarball creation fails
release::gcs::prepare_tarball() {
  local gcs_stage=$1
  shift
  local src
  local srcdir
  local srcthing
  local args
  local split
  local srcs
  local dst

  # Split the args into srcs... and dst
  local args=("$@")
  local split=$((${#args[@]}-1)) # Split point for src/dst args
  local srcs=("${args[@]::$split}" )
  local dst="${args[$split]}"

  logrun mkdir -p $gcs_stage/$dst || return 1

  for src in ${srcs[@]}; do
    srcdir=$(dirname $src)
    srcthing=$(basename $src)
    tar c -C $srcdir $srcthing | tar x -C $gcs_stage/$dst || return 1
  done
}

###############################################################################
# Ensure the destination bucket path doesn't already exist
# @param gcs_destination - GCS destination directory
# @return 1 on failure or if GCS destination already exists
#           and --allow_dup does not set
release::gcs::destination_empty() {
  local gcs_destination=$1

  logecho -n "Checking whether $gcs_destination already exists: "
  if $GSUTIL ls $gcs_destination >/dev/null 2>&1 ; then
    logecho "- Destination exists. To remove, run:"
    logecho "  gsutil -m rm -r $gcs_destination"

    if ((FLAGS_allow_dup)) ; then
      logecho "flag --allow-dup set, continue with overwriting"
    else
      logecho "$FAILED"
      return 1
    fi
  fi
  logecho "$OK"
}

###############################################################################
# Push the release artifacts to GCS
# @param src - Source path
# @param dest - Destination path
# @return 1 on failure
release::gcs::push_release_artifacts() {
  local src=$1
  local dest=$2

  logecho "Publish public release artifacts..."

  # No need to check this for mock or stage runs
  # Overwriting is ok
  if ((FLAGS_nomock)) && ! ((FLAGS_stage)); then
    release::gcs::destination_empty $dest || return 1
  fi

  # Copy the main set from staging to destination
  # We explicitly don't set an ACL in the cp call, since doing so will override
  # any default bucket ACLs.
  logecho -n "- Copying artifacts to $dest: "
  logrun -s $GSUTIL -qm cp -rc $src/* $dest/ || return 1

  # This small sleep gives the eventually consistent GCS bucket listing a chance
  # to stabilize before the diagnostic listing. There's no way to directly
  # query for consistency, but it's OK if something is dropped from the
  # debugging output.
  sleep 5

  logecho -n "- Listing final contents to log file: "
  logrun -s $GSUTIL ls -lhr "$dest" || return 1
}

###############################################################################
# Locally stage the release artifacts to staging directory
# @param version - The version
# @param build_output - build output directory
# @optparam release_kind - defaults to kubernetes
# @return 1 on failure
release::gcs::locally_stage_release_artifacts() {
  local version=$1
  local build_output=$2
  # --release-kind used by push-build.sh
  local release_kind=${3:-"kubernetes"}
  local platform
  local release_stage=$build_output/release-stage
  local release_tars=$build_output/release-tars
  local gcs_stage=$build_output/gcs-stage/$version
  local configure_vm
  local src
  local dst

  logecho "Locally stage release artifacts..."

  logrun rm -rf $gcs_stage || return 1
  logrun mkdir -p $gcs_stage || return 1

  # Stage everything in release directory
  logecho "- Staging locally to ${gcs_stage##$build_output/}..."
  release::gcs::prepare_tarball $gcs_stage $release_tars/* . || return 1

  # Controls whether we publish md5 / sha1; clear to prevent publishing
  # Although we would like to encourage users to stop using md5 / sha1,
  # because all releases are published by the master branch, this broke
  # anyone that was verifying the sha1 hash, including in CI builds.
  # kops caught this in e.g. https://prow.k8s.io/view/gcs/kubernetes-jenkins/pr-logs/pull/kops/7462/pull-kops-e2e-kubernetes-aws/1164899358911500292/
  # Instead we need to stop publishing sha1 and md5 on a release boundary.
  local publish_old_hashes="1"

  if [[ "$release_kind" == "kubernetes" ]]; then
    if ! [[ $version =~ ${VER_REGEX[release]} ]]; then
      logecho -r "$FAILED"
      logecho "* Invalid version format! $version"
      return 1
    fi

    local -r version_major="${BASH_REMATCH[1]}"
    local -r version_minor="${BASH_REMATCH[2]}"
    local -r version_patch="${BASH_REMATCH[3]}"

    # Don't publish md5 & sha1 as of Kubernetes 1.18
    if [[ "$version_minor" -ge "18" ]]; then
      publish_old_hashes=""
    fi

    local gce_path=$release_stage/full/kubernetes/cluster/gce
    local gci_path

    # GCI path changed in 1.2->1.3 time period
    if [[ -d $gce_path/gci ]]; then
      gci_path=$gce_path/gci
    else
      gci_path=$gce_path/trusty
    fi

    # Having the configure-vm.sh script and trusty code from the GCE cluster
    # deploy hosted with the release is useful for GKE.
    # Take it if available (Removed in 1.10+)
    [[ -f $gce_path/configure-vm.sh ]] \
     && configure_vm="$gce_path/configure-vm.sh"

    release::gcs::prepare_tarball $gcs_stage $configure_vm extra/gce \
      || return 1
    release::gcs::prepare_tarball $gcs_stage $gci_path/node.yaml extra/gce \
      || return 1
    release::gcs::prepare_tarball $gcs_stage $gci_path/master.yaml extra/gce \
      || return 1
    release::gcs::prepare_tarball $gcs_stage $gci_path/configure.sh extra/gce \
      || return 1

    # shutdown.sh was introduced starting from v1.11 to make Preemptible COS nodes
    # on GCP not reboot immediately when terminated. Avoid including it in the release
    # bundle if it is not found (for backwards compatibility).
    if [[ -f $gci_path/shutdown.sh ]]; then
      release::gcs::prepare_tarball $gcs_stage $gci_path/shutdown.sh extra/gce \
       || return 1
    fi

    # Having the Windows startup scripts from the GCE cluster deploy hosted with
    # the release is useful for GKE.
    windows_local_path=$gce_path/windows
    windows_gcs_path=extra/gce/windows
    if [[ -d $windows_local_path ]]; then
      release::gcs::prepare_tarball $gcs_stage $windows_local_path/configure.ps1 $windows_gcs_path \
        || return 1
      release::gcs::prepare_tarball $gcs_stage $windows_local_path/common.psm1 $windows_gcs_path \
        || return 1
      release::gcs::prepare_tarball $gcs_stage $windows_local_path/k8s-node-setup.psm1 $windows_gcs_path \
        || return 1
      release::gcs::prepare_tarball $gcs_stage $windows_local_path/testonly/install-ssh.psm1 $windows_gcs_path \
        || return 1
      release::gcs::prepare_tarball $gcs_stage $windows_local_path/testonly/user-profile.psm1 $windows_gcs_path \
        || return 1
    fi

  fi

  # Upload the "naked" binaries to GCS.  This is useful for install scripts that
  # download the binaries directly and don't need tars.
  mapfile -t platforms < <(find "${release_stage}/client" -maxdepth 1 -mindepth 1 -exec basename {} \;)
  for platform in "${platforms[@]}"; do
    src="$release_stage/client/$platform/$release_kind/client/bin/*"
    dst="bin/${platform/-//}/"
    # We assume here the "server package" is a superset of the "client package"
    if [[ -d "$release_stage/server/$platform" ]]; then
      src="$release_stage/server/$platform/$release_kind/server/bin/*"
    fi
    release::gcs::prepare_tarball $gcs_stage "$src" "$dst" || return 1

    # Upload node binaries if they exist and this isn't a 'server' platform.
    if [[ ! -d "$release_stage/server/$platform" ]]; then
      if [[ -d "$release_stage/node/$platform" ]]; then
        src="$release_stage/node/$platform/$release_kind/node/bin/*"
        release::gcs::prepare_tarball $gcs_stage "$src" "$dst" || return 1
      fi
    fi
  done

  # Write the release checksum files.
  # We checksum everything except our checksum files, which we do next.
  logecho "- Writing artifact hashes to SHA256SUMS/SHA512SUMS files..."
  find "${gcs_stage}" -type f -printf '%P\0' | xargs -0 -I {} shasum -a 256 "${gcs_stage}/{}" >> SHA256SUMS
  find "${gcs_stage}" -type f -printf '%P\0' | xargs -0 -I {} shasum -a 512 "${gcs_stage}/{}" >> SHA512SUMS
  # After all the checksum files are generated, move them into the bucket staging area
  mv SHA256SUMS SHA512SUMS "$gcs_stage"

  logecho "- Hashing files in ${gcs_stage##$build_output/}..."
  find "$gcs_stage" -type f | while read -r path; do
    if [[ -n "${publish_old_hashes}" ]]; then
      common::md5 "$path" > "$path.md5" || return 1
      common::sha "$path" 1 > "$path.sha1" || return 1
    fi

    common::sha "$path" 256 > "$path.sha256" || return 1
    common::sha "$path" 512 > "$path.sha512" || return 1
  done
}

###############################################################################
# Publish a new version, (latest or stable,) but only if the
# files actually exist on GCS and the artifacts we're dealing with are newer
# than the contents in GCS.
# @param build_type - One of 'release' or 'ci'
# @param version - The version
# @param build_output - build output directory
# @param bucket - GS bucket
# @return 1 on failure
release::gcs::publish_version () {
  local build_type=$1
  local version=$2
  local build_output=$3
  local bucket=$4
  local extra_version_markers=$5
  local release_dir
  local version_major
  local version_minor
  local publish_file
  local -a publish_files
  local type="latest"

  # For release/ targets, type could be 'stable'
  if [[ "$build_type" == release ]]; then
    [[ "$version" =~ alpha|beta|rc ]] || type="stable"
  fi

  # Ensure we check for "fast" (linux/amd64-only) build artifacts in the /fast
  # subdirectory instead of the "root" of the build directory
  if ((FLAGS_fast)); then
    release_dir="gs://$bucket/$build_type/fast/$version"
  else
    release_dir="gs://$bucket/$build_type/$version"
  fi

  if ! logrun $GSUTIL ls $release_dir; then
    logecho "Release files don't exist at $release_dir"
    return 1
  fi

  if [[ $version =~ ${VER_REGEX[release]} ]]; then
    version_major=${BASH_REMATCH[1]}
    version_minor=${BASH_REMATCH[2]}
  fi

  if ((FLAGS_fast)); then
    publish_files=(
      "$type-fast"
    )
  else
    publish_files=(
      "$type"
      "$type-$version_major"
      "$type-$version_major.$version_minor"
    )
  fi

  for marker in "${extra_version_markers[@]}"; do
    publish_files+=("$marker")
  done

  logecho
  logecho "Publish version markers: ${publish_files[*]}"

  logecho
  logecho "Publish official pointer text files to $bucket..."

  for publish_file in ${publish_files[@]}; do
    # If there's a version that's above the one we're trying to release, don't
    # do anything, and just try the next one.
    release::gcs::verify_latest_update $build_type/$publish_file.txt \
                                    $bucket $version || continue
    release::gcs::publish $build_type/$publish_file.txt $build_output \
                          $bucket $version || return 1
  done
}

###############################################################################
# Check if the new version is greater than the version currently published on
# GCS.
# @param publish_file - the GCS location to look in
# @param bucket - GS bucket
# @param version - release version
# @optparam publish_file_dst - (for testing)
# @return 1 if new version is not greater than the GCS version
release::gcs::verify_latest_update () {
  local -r publish_file=$1
  local -r bucket=$2
  local -r version=$3
  local -r publish_file_dst=${4:-"gs://$bucket/$publish_file"}
  local gcs_version
  local greater=1

  logecho -n "Test $version > $publish_file (published): "
  if ! [[ $version =~ ${VER_REGEX[release]}(.${VER_REGEX[build]})* ]]; then
    logecho -r "$FAILED"
    logecho "* Invalid version format! $version"
    return 1
  fi

  local -r version_major="${BASH_REMATCH[1]}"
  local -r version_minor="${BASH_REMATCH[2]}"
  local -r version_patch="${BASH_REMATCH[3]}"
  local -r version_prerelease="${BASH_REMATCH[4]}"
  local -r version_prerelease_rev="${BASH_REMATCH[5]}"
  local -r version_commits="${BASH_REMATCH[7]}"

  local -a catCmd=( 'cat' "$publish_file_dst" )
  [ -n "${GSUTIL:-}" ] && catCmd=( "$GSUTIL" "${catCmd[@]}" )

  if gcs_version="$( "${catCmd[@]}" )"; then
    if ! [[ $gcs_version =~ ${VER_REGEX[release]}(.${VER_REGEX[build]})* ]]; then
      logecho -r "$FAILED"
      logecho "* file contains invalid release version," \
              "can't compare: '$gcs_version'"
      return 1
    fi

    local -r gcs_version_major="${BASH_REMATCH[1]}"
    local -r gcs_version_minor="${BASH_REMATCH[2]}"
    local -r gcs_version_patch="${BASH_REMATCH[3]}"
    local -r gcs_version_prerelease="${BASH_REMATCH[4]}"
    local -r gcs_version_prerelease_rev="${BASH_REMATCH[5]}"
    local -r gcs_version_commits="${BASH_REMATCH[7]}"

    if [[ "$version_major" -lt "$gcs_version_major" ]]; then
      greater=0
    elif [[ "$version_major" -gt "$gcs_version_major" ]]; then
      : # fall out
    elif [[ "$version_minor" -lt "$gcs_version_minor" ]]; then
      greater=0
    elif [[ "$version_minor" -gt "$gcs_version_minor" ]]; then
      : # fall out
    elif [[ "$version_patch" -lt "$gcs_version_patch" ]]; then
      greater=0
    elif [[ "$version_patch" -gt "$gcs_version_patch" ]]; then
      : # fall out
    # Use lexicographic (instead of integer) comparison because
    # version_prerelease is a string, ("alpha", "beta", or "rc"),
    # but first check if either is an official release
    # (i.e. empty prerelease string).
    #
    # We have to do this because lexicographically "rc" > "beta" > "alpha" > "",
    # but we want official > rc > beta > alpha.
    elif [[ -n "$version_prerelease" && -z "$gcs_version_prerelease" ]]; then
      greater=0
    elif [[ -z "$version_prerelease" && -n "$gcs_version_prerelease" ]]; then
      : # fall out
    elif [[ "$version_prerelease" < "$gcs_version_prerelease" ]]; then
      greater=0
    elif [[ "$version_prerelease" > "$gcs_version_prerelease" ]]; then
      : # fall out
    # The only reason we want to NOT update in the 'equals' case
    # is to maintain publish_file timestamps for the original 'equals' version.
    # for release if the new version is <=, Do Not Publish
    # for ci if the new version is strictly <, Do Not Publish
    elif [[ $publish_file =~ ^release && \
            "$version_prerelease_rev" -le "$gcs_version_prerelease_rev" ]] ||\
         [[ $publish_file =~ ^ci && \
            "$version_prerelease_rev" -lt "$gcs_version_prerelease_rev" ]]; then
      greater=0
    elif [[ "$version_prerelease_rev" -gt "$gcs_version_prerelease_rev" ]]; then
      : # fall out
    # If either version_commits is empty, it will be considered less-than, as
    # expected, (e.g. 1.2.3-beta < 1.2.3-beta.1).
    elif [[ "$version_commits" -lt "$gcs_version_commits" ]]; then
      greater=0
    fi

    if ((greater)); then
      logecho -r "$OK"
      logecho "* $version > $gcs_version (published), updating"
    else
      logecho "$WARNING"
      logecho "* $version <= $gcs_version (published) - not updating."
      return 1
    fi
  else
    # gsutil cat failed; file does not exist
    logecho -r "$OK"
    logecho "* $publish_file_dst does not exist yet. It will be created..."
    return 0
  fi
}

###############################################################################
# Publish a release to GCS: upload a version file, if --nomock,
# make it public, and verify the result.
# @param publish_file - the GCS location to look in
# @param build_output - build output directory
# @param bucket - GS bucket
# @param version - release version
# @optparam bucket_mirror - (optional) mirror GS bucket
# @return 1 on failure
release::gcs::publish () {
  local publish_file=$1
  local build_output=$2
  local bucket=$3
  local version=$4
  local release_stage=$build_output/release-stage
  local publish_file_dst="gs://$bucket/$publish_file"
  local contents
  local public_link="https://storage.googleapis.com/$bucket/$publish_file"

  if [[ "$bucket" == "$PROD_BUCKET" ]]; then
    public_link="https://dl.k8s.io/$publish_file"
  fi

  logrun mkdir -p "$release_stage/upload" || return 1
  echo "$version" > "$release_stage/upload/latest" || return 1

  logrun $GSUTIL -m -h "Content-Type:text/plain" \
    -h "Cache-Control:private, max-age=0, no-transform" cp \
    "$release_stage/upload/latest" \
    "$publish_file_dst" || return 1

  if ((FLAGS_nomock)) && ! ((FLAGS_private_bucket)); then
    # New Kubernetes infra buckets, like k8s-staging-kubernetes, have a
    # bucket-only ACL policy set, which means attempting to set the ACL on an
    # object will fail. We should skip this ACL change in those instances, as
    # new buckets already default to being publicly readable.
    #
    # Ref:
    # - https://cloud.google.com/storage/docs/bucket-policy-only
    # - https://github.com/kubernetes/release/issues/904
    if ! [[ "$bucket" =~ ^k8s- ]]; then
      logecho -n "Making uploaded version file public: "
      logrun -s $GSUTIL acl ch -R -g all:R $publish_file_dst || return 1
    fi

    # If public, validate public link
    logecho -n "* Validating uploaded version file at $public_link: "
    contents="$(curl --retry 5 -Ls $public_link)"
  else
    # If not public, validate using gsutil
    logecho -n "* Validating uploaded version file at $publish_file_dst: "
    contents="$($GSUTIL cat $publish_file_dst)"
  fi

  if [[ "$contents" == "$version" ]]; then
    logecho "$OK"
  else
    logecho "$FAILED (file contents: $contents)"
    return 1
  fi
}

###############################################################################
# Releases all docker images to a docker registry using the docker tarfiles.
#
# @param registry - docker registry
# @param version - version tag
# @param build_output - build output directory
# @return 1 on failure
release::docker::release () {
  local registry="$1"
  local push_registry="$registry"
  local version="$2"
  local build_output="$3"
  local release_images="$build_output/release-images"
  local arch
  local tarfile
  local orig_tag
  local new_tag
  local binary
  local -A manifest_images

  common::argc_validate 3

  logecho "Send docker containers from release-images to $push_registry..."

  mapfile -t arches < <(find "${release_images}" -maxdepth 1 -mindepth 1 -type d -exec basename {} \;)
  for arch in "${arches[@]}"; do
    for tarfile in $release_images/$arch/*.tar; do
      # There may be multiple tags; just get the first
      orig_tag=$(tar xf $tarfile manifest.json -O  | jq -r '.[0].RepoTags[0]')
      if [[ ! "$orig_tag" =~ ^.+/(.+):.+$ ]]; then
        logecho "$FAILED: malformed tag in $tarfile:"
        logecho $orig_tag
        return 1
      fi
      binary=${BASH_REMATCH[1]}

      new_tag="$push_registry/${binary/-$arch/}"
      new_tag_with_arch=("$new_tag-$arch:$version")
      manifest_images["${new_tag}"]+=" $arch"

      logrun docker load -qi $tarfile
      logrun docker tag $orig_tag ${new_tag_with_arch}
      logecho -n "Pushing ${new_tag_with_arch}: "
      # TODO: Use docker direct when fixed later
      #logrun -r 5 -s docker push "${new_tag_with_arch}" || return 1
      logrun -r 5 -s $GCLOUD docker -- push "${new_tag_with_arch}" || return 1
      if [[ "${PURGE_IMAGES:-yes}" == "yes" ]] ; then
        logrun docker rmi $orig_tag ${new_tag_with_arch} || true
      fi

    done
  done

  # Ensure that the docker command line supports the manifest images
  export DOCKER_CLI_EXPERIMENTAL=enabled

  for image in "${!manifest_images[@]}"; do
    local archs=$(echo "${manifest_images[$image]}" | sed -e 's/^[[:space:]]*//')
    local manifest=$(echo $archs | sed -e "s~[^ ]*~$image\-&:$version~g")
    # This command will push a manifest list: "${registry}/${image}-ARCH:${version}" that points to each architecture depending on which platform you're pulling from
    logecho "Creating manifest image ${image}:${version}..."
    logrun -r 5 -s docker manifest create --amend ${image}:${version} ${manifest} || return 1
    for arch in ${archs}; do
      logecho "Annotating ${image}-${arch}:${version} with --arch ${arch}..."
      logrun -r 5 -s docker manifest annotate --arch ${arch} ${image}:${version} ${image}-${arch}:${version} || return 1
    done
    logecho "Pushing manifest image ${image}:${version}..."
    local purge=""
    if [[ "${PURGE_IMAGES:-yes}" == "yes" ]] ; then
      purge="--purge"
    fi
    logrun -r 5 -s docker manifest push ${image}:${version} ${purge} || return 1
  done

  # Always reset back to $GCP_USER
  # This is set in push-build.sh and anago
  ((FLAGS_gcb)) || logrun $GCLOUD config set account $GCP_USER

  return 0
}

###############################################################################
# Determine whether the release was most recently built with Bazel.
# This is achieved by looking for the most recent kubernetes.tar.gz tarball
# in both the dockerized and Bazel output trees.
# @param kube_root - Root of kubernetes tree
# @param release_kind - Kind of release. kubernetes or federation
# @return 0 if built with Bazel, 1 otherwise
release::was_built_with_bazel() {
  local kube_root=$1
  local release_kind=$2
  local most_recent_release_tar=$( (ls -t \
    $kube_root/{_output,bazel-bin/build}/release-tars/$release_kind.tar.gz \
    2>/dev/null || true) | head -n 1)

  [[ $most_recent_release_tar =~ /bazel-bin/ ]]
}

###############################################################################
# Copy the release artifacts to a local staging dir and push them up to GCS
# using the Bazel "push-build" rule.
# @param build_type - One of 'release' or 'ci'
# @param version - The version
# @param build_output - legacy build output directory; artifacts will be copied
#                       here for use by CI
# @param bucket - GS bucket
# @return 1 on failure
release::gcs::bazel_push_build() {
  local build_type=$1
  local version=$2
  local build_output=$3
  local bucket=$4
  # We don't need to locally stage, but CI uses this.
  # TODO: make it configurable whether we also stage locally
  local gcs_stage=$build_output/gcs-stage/$version
  local gcs_destination=gs://$bucket/$build_type/$version

  logrun rm -rf $gcs_stage || return 1
  logrun mkdir -p $gcs_stage || return 1

  # No need to check this for mock or stage runs
  # Overwriting is ok
  if ((FLAGS_nomock)) && ! ((FLAGS_stage)); then
    release::gcs::destination_empty $gcs_destination || return 1
  fi

  logecho "Publish release artifacts to gs://$bucket using Bazel..."
  logecho "- Hashing and copying public release artifacts to $gcs_destination: "
  bazel run //:push-build $gcs_stage $gcs_destination || return 1

  # This small sleep gives the eventually consistent GCS bucket listing a chance
  # to stabilize before the diagnostic listing. There's no way to directly
  # query for consistency, but it's OK if something is dropped from the
  # debugging output.
  sleep 5

  logecho -n "- Listing final contents to log file: "
  logrun -s $GSUTIL ls -lhr "$gcs_destination" || return 1
}

##############################################################################
# Initialize logs
##############################################################################
# Initialize and save up to 10 (rotated logs)
MYLOG=$TMPDIR/$PROG.log
common::logfileinit $MYLOG 10

# BEGIN script
common::timestamp begin

###############################################################################
# MAIN
###############################################################################
RELEASE_BUCKET="${FLAGS_bucket:-"$CI_BUCKET"}"

# Compatibility with incoming global args
[[ $KUBE_GCS_UPDATE_LATEST == "n" ]] && FLAGS_noupdatelatest=1

# Default to kubernetes
: ${FLAGS_release_kind:="kubernetes"}

# This will canonicalize the path
KUBE_ROOT=$(pwd -P)

# TODO: this should really just read the version from the release tarball always
USE_BAZEL=false
if release::was_built_with_bazel $KUBE_ROOT $FLAGS_release_kind; then
  USE_BAZEL=true
  # The check for version in bazel-genfiles can be removed once everyone is off
  # of versions before 0.25.0.
  # https://github.com/bazelbuild/bazel/issues/8651
  if [[ -r  "$KUBE_ROOT/bazel-genfiles/version" ]]; then
    LATEST=$(cat $KUBE_ROOT/bazel-genfiles/version)
  else
    LATEST=$(cat $KUBE_ROOT/bazel-bin/version)
  fi
else
  LATEST=$(tar -O -xzf $KUBE_ROOT/_output/release-tars/$FLAGS_release_kind.tar.gz $FLAGS_release_kind/version)
fi

if [[ "$LATEST" =~ (${VER_REGEX[release]}(\.${VER_REGEX[build]})?(-dirty)?) ]]; then
  if ((FLAGS_ci)) && [[ "$LATEST" =~ "dirty" ]]; then
    logecho "Refusing to push dirty build with --ci flag given."
    logecho "CI builds should always be performed from clean commits."
    logecho
    logecho "version output:"
    logecho $LATEST
    common::exit 1
  fi
else
  logecho "Unable to get latest version from build tree!"
  logecho
  logecho "version output:"
  logecho $LATEST
  common::exit 1
fi

if [[ -n "${FLAGS_version_suffix:-}" ]]; then
  LATEST+="-${FLAGS_version_suffix}"
fi

GCS_DEST="devel"
((FLAGS_ci)) && GCS_DEST="ci"
GCS_DEST=${FLAGS_release_type:-$GCS_DEST}
GCS_DEST+="$FLAGS_gcs_suffix"
GCS_EXTRA_VERSION_MARKERS_STRING="${FLAGS_extra_version_markers:-${FLAGS_extra_publish_file:-}}"


PREVIOUS_IFS=$IFS
IFS=',' read -ra GCS_EXTRA_VERSION_MARKERS <<< "$GCS_EXTRA_VERSION_MARKERS_STRING"
IFS=$PREVIOUS_IFS

logecho
logecho "Will publish extra version markers: ${GCS_EXTRA_VERSION_MARKERS[*]}"
logecho

if ((FLAGS_nomock)); then
  logecho
  logecho "$PROG is running a *REAL* push!!"
  logecho
else
  # Point to a $USER playground
  RELEASE_BUCKET+=-$USER
fi

##############################################################################
common::stepheader CHECK PREREQUISITES
##############################################################################
if ! common::set_cloud_binaries; then
  logecho "Releasing Kubernetes requires gsutil and gcloud. Please download,"
  logecho "install and authorize through the Google Cloud SDK:"
  logecho
  logecho "https://developers.google.com/cloud/sdk/"
  common::exit 1
fi

# Nothing should work without this.  The entire release workflow depends
# on it whether running from the desktop or GCB
GCP_USER=$($GCLOUD auth list --filter=status:ACTIVE \
                             --format="value(account)" 2>/dev/null)
[[ -n "$GCP_USER" ]] || common::exit 1 "Unable to set a valid GCP credential!"

logecho -n "Check release bucket $RELEASE_BUCKET: "
logrun -s release::gcs::check_release_bucket $RELEASE_BUCKET || common::exit 1

# These operations can hit bumps and are re-entrant so retry up to 3 times
max_attempts=3
##############################################################################
common::stepheader COPY RELEASE ARTIFACTS
##############################################################################
attempt=0
while ((attempt<max_attempts)); do
  if $USE_BAZEL; then
    release::gcs::bazel_push_build $GCS_DEST $LATEST $KUBE_ROOT/_output \
                                   $RELEASE_BUCKET && break
  else
    release::gcs::locally_stage_release_artifacts $LATEST \
                                                  $KUBE_ROOT/_output \
                                                  $FLAGS_release_kind

    if ((FLAGS_fast)); then
      BUILD_DEST="$GCS_DEST/fast"
    else
      BUILD_DEST="$GCS_DEST"
    fi

    release::gcs::push_release_artifacts \
     $KUBE_ROOT/_output/gcs-stage/$LATEST \
     gs://$RELEASE_BUCKET/$BUILD_DEST/$LATEST && break
  fi
  ((attempt++))
done
((attempt>=max_attempts)) && common::exit 1 "Exiting..."

if [[ -n "${FLAGS_docker_registry:-}" ]]; then
  ##############################################################################
  common::stepheader PUSH DOCKER IMAGES
  ##############################################################################
  # TODO: support Bazel too
  # Docker tags cannot contain '+'
  release::docker::release $FLAGS_docker_registry ${LATEST/+/_} \
    $KUBE_ROOT/_output
fi

# If not --ci, then we're done here.
((FLAGS_ci)) || common::exit 0 "Exiting..."

if ! ((FLAGS_noupdatelatest)); then
  ##############################################################################
  common::stepheader UPLOAD to $RELEASE_BUCKET
  ##############################################################################
  attempt=0
  while ((attempt<max_attempts)); do
    release::gcs::publish_version $GCS_DEST $LATEST $KUBE_ROOT/_output \
                                  $RELEASE_BUCKET $GCS_EXTRA_VERSION_MARKERS && break
    ((attempt++))
  done
  ((attempt>=max_attempts)) && common::exit 1 "Exiting..."
fi

# Leave push-federation-images.sh for now.  Not sure if this makes sense to
# pull into the release repo.
if ((FLAGS_federation)); then
  ############################################################################
  common::stepheader PUSH FEDERATION
  ############################################################################
  logecho -n "Push federation images: "
  # FEDERATION_PUSH_REPO_BASE should be set by the calling job (yaml)
  logrun -s ${KUBE_ROOT}/federation/develop/push-federation-images.sh
fi

# END script
common::timestamp end
