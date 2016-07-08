#!/bin/bash

VARGS=$@
set -e nounset

describe_aws_load_balancer_instances() {
  aws elb describe-load-balancers \
    --load-balancer-names vulcand-major \
  | jq '.LoadBalancerDescriptions[0].Instances'
}

get_index_index(){
  local instances="$1"
  local instances_count=$(echo "$instances" | jq '. | length')
  local instance_index=$(jot -r 1 1 $instances_count)
  let "instance_index = $instance_index - 1"
  echo "$instance_index"
}

get_random_instance_id(){
  local instances="$1"
  local instance_index=$(get_index_index "$instances")

  echo "$instances" | jq --raw-output ".[$instance_index].InstanceId"
}

get_ip_for_instance_id(){
  local instance_id="$1"
  aws ec2 describe-instances --instance-ids "$instance_id" \
  | jq --raw-output '.Reservations[0].Instances[0].PublicIpAddress'
}

get_major_ip(){
  local instances="$(describe_aws_load_balancer_instances)"
  local instance_id=$(get_random_instance_id "$instances")
  local ip_address="$(get_ip_for_instance_id "$instance_id")"

  echo "$ip_address"
}

establish_ssh_tunnel(){
  local ip_address="$1"

  ssh -t -t -L 61222:localhost:8182 "core@$ip_address" &> /dev/null
}

kill_ssh_tunnel_job() {
  local parent_pid="$1"
  pkill -P "$parent_pid" -f 'ssh -t -t -L 61222:localhost:8182'
}

wait_for_tunnel() {
  local tunnel_open="1"
  while [ "$tunnel_open" != "0" ]; do
    echo -n "."
    curl http://localhost:61222 &> /dev/null
    tunnel_open="$?"
    sleep 0.25
  done
  echo ""
}

assert_port_free() {
  curl http://localhost:61222 &> /dev/null
  local exit_code="$?"
  if [ "$exit_code" == "0" ]; then
    echo "Port 61222 seems to be in use, cowardly refusing to do anything"
    exit 1
  fi
}

assert_vctl_capabilities() {
  vctl --help | grep 'job-logger' &> /dev/null

  local exit_code="$?"
  if [ "${exit_code}" != "0" ]; then
    echo "vctl doesn't know about job-logger. Proudly refusing to use imported software"
    echo "go get github.com/octoblu/vulcand-bundle/vctl"
    exit $exit_code
  fi
}

do_vulcan_sync() {
  local vulcan_url="$1"
  local project_name="$2"

  sync_backend "${vulcan_url}" "${project_name}"
  sync_frontend "${vulcan_url}" "${project_name}"
  for middleware in ${HOME}/Projects/Octoblu/the-stack-env-production/vulcan.d/${project_name}/middlewares/*; do
    sync_middleware "${vulcan_url}" "${project_name}" "${middleware}"
  done
}

sync_backend(){
  local vulcan_url="$1"
  local project_name="$2"
  local args=$(cat "${HOME}/Projects/Octoblu/the-stack-env-production/vulcan.d/${project_name}/backend")
  vctl --vulcan "${vulcan_url}" backend upsert $args
}

sync_frontend(){
  local vulcan_url="$1"
  local project_name="$2"
  local args=$(cat "${HOME}/Projects/Octoblu/the-stack-env-production/vulcan.d/${project_name}/frontend")
  vctl --vulcan "${vulcan_url}" frontend upsert $args
}

sync_middleware(){
  local vulcan_url="$1"
  local project_name="$2"
  local middleware="$3"
  local middleware_type=$(basename "${middleware}")
  local args=$(cat "${middleware}")

  vctl --vulcan "${vulcan_url}" "${middleware_type}" upsert $args
}

usage(){
  echo "USAGE: vulcansync <load/l> <project-name> [project-name]..."
  echo ""
  echo "example: vulcansync octoblu-governator-service"
  echo ""
  echo "the vulcan url can be overridden using VULCAN_URL."
  echo "vulcansync will not establish an SSH connection if"
  echo "a VULCAN_URL is specified"
  echo ""
  echo "  -h, --help      print this help text"
  echo "  -v, --version   print the version"
  echo ""
}

validate_cmd() {
  local cmd="$1"

  if [ "$cmd" == "load" -o "$cmd" == "l" ]; then
    return
  fi

  echo "Command must be one of load/l"
  usage
  exit 1
}

script_directory(){
  local source="${BASH_SOURCE[0]}"
  local dir=""

  while [ -h "$source" ]; do # resolve $source until the file is no longer a symlink
    dir="$( cd -P "$( dirname "$source" )" && pwd )"
    source="$(readlink "$source")"
    [[ $source != /* ]] && source="$dir/$source" # if $source was a relative symlink, we need to resolve it relative to the path where the symlink file was located
  done

  dir="$( cd -P "$( dirname "$source" )" && pwd )"

  echo "$dir"
}

version(){
  local directory="$(script_directory)"
  local version=$(cat "$directory/VERSION")

  echo "$version"
  exit 0
}

main(){
  local vulcan_url="$VULCAN_URL"
  local cmd="$1"; shift
  local projects=( $@ )

  if [ "$cmd" == "--help" -o "$cmd" == "-h" ]; then
    usage
    exit 0
  fi

  if [ "$cmd" == "--version" -o "$cmd" == "-v" ]; then
    version
    exit 0
  fi

  for project in "${projects[@]}"; do
    if [ "$project" == "--help" -o "$project" == "-h" ]; then
      usage
      exit 0
    fi

    if [ "$project" == "--version" -o "$project" == "-v" ]; then
      version
      exit 0
    fi
  done

  validate_cmd "$cmd"

  if [ -n "$vulcan_url" ]; then
    for project in "${projects[@]}"; do
      do_vulcan_sync "$vulcan_url" "$project" "$cmd"
    done
    exit $?
  fi

  assert_vctl_capabilities
  assert_port_free

  local ip_address="$(get_major_ip)"
  establish_ssh_tunnel "$ip_address" & # in the background
  local ssh_tunnel_job="$!"

  echo -n "Waiting for tunnel"
  wait_for_tunnel
  echo "Tunnel established, working."
  for project in "${projects[@]}"; do
    do_vulcan_sync http://localhost:61222 "$project" "$cmd"
    local exit_code=$?

    if [ "$exit_code" != "0" ]; then
      echo "Fatal Error: $exit_code"
      echo $exit_code
    fi
  done

  kill_ssh_tunnel_job "$ssh_tunnel_job"
  exit 0
}

main $VARGS
