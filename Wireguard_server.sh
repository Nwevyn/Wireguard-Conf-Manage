#!/bin/bash

# functions
function _verbose() {
  if (( $verbose >= $1 )); then
    echo -e "$2"
  fi
}

function get_defaults()
{
  local _string="$(printf '%08x%08x%s' $(date +%s) $(date +%N | sed 's/^0*//') $(ip addr show dev $(ip route show to default | cut -d ' ' -f5) | grep link/ | sed 's/^ *//' | cut -d ' ' -f2 | tr -d :) | sha1sum | cut -d ' ' -f1)"

  dryrun=n
  wireguard_server_dir="/etc/wireguard"
  interface="wg0"
  ipv4="$(printf '10.%d.%d.1/24' $((16#${_string:36:2})) $((16#${_string:38:2})))"
  ipv6="fd${_string:30:2}:${_string:32:4}:${_string:36:4}::1/64"
  listenport="51820"
  fwmark=""
  endpoint=$(ip addr show dev $(ip route show to default | cut -d ' ' -f5) | grep --regex 'inet6 [23].*global' | grep -v 'deprecated' | sed 's/^ *//' | cut -d ' ' -f2 | cut -d '/' -f1)
  mtu=""
  table=""
  preup=""
  postup=""
  predown=""
  postdown=""
  saveconfig="false"
  dns=""
  persistentkeepalive="0"
  allowedips="0.0.0.0/0,::/0"
  return
}

function usage()
{
   _verbose $trace "function: $depth${FUNCNAME[0]}"; depth=" $depth"

   cat << HEREDOC

   Usage: $progname [--interface $interface] [--directory $wireguard_server_dir] /
                    [--ipv4 $ipv4] [-ipv6 $ipv6] /
                    [--port $listenport] [--dns DNS.SERVER] [--mtu nnnn] /
                    [--fwmark MARK] [--table TABLENAME] [--save] /
                    [--preup 'command'] [--postup 'command'] /
                    [--predown 'command] [--postdown 'command'] /
                    [--endpoint URL|IPV4-address|IPv6-address] /
                    [--keepalive SECONDS] [--allowedips "$allowedips"] /
                    [--help] [--verbose] [--dry-run]

   arguments:
    interface configuration file:
     -i, --interface DEV   Interface to update:
                               If omitted, defaults to $interface
     -D, --directory DIR   Wireguard configuration directory for "server"
                               If omitted, defaults to $wireguard_server_dir
   interface options:
     -4, --ipv4 IPv4-ADDR  This is the interface's IPv4 address.
                               If omitted, defaults to "$ipv4"
                               Use "-4 ''" to not use IPv4
     -6  --ipv6 IPv6-ADDR  This is the interface's IPv6 address
                               If omitted, defaults to "$ipv6"
                               Use "-6 ''" to not use IPv6
     -p, --port PORT       UDP port used to communcate with the "server"
                               If omitted, defaults to "$listenport"
     -d, --dns SERVER.ADDR Domain Name Server used by the interface.
                               Repeated uses will append the SERVER.ADDR in order
     -m, --mtu SIZE        The maximum packet size used by the "server"
     -f, --fwmark MARK     Forward mark to be used by the "server"
     -t, --table TABLE     Table name used by the interface
     -s, --save            When present, the SaveConfig will be set to "true"
                               When ommitted, the SaveConfig will be set to "false"
         --postup CMD      Commands to be issued after bringing up the interface
                               Multiple entries will be concatenated
         --postdown CMD    Commands to be issued after bringing down the interface
                               Multiple entries will be concatenated
         --preup CMD       Commands to be issued before bringing up the interface
                               Multiple entries will be concatenated
         --predown CMD     Commands to be issued before bringing down the interface
                               Multiple entries will be concatenated
   Peer options (to be used by Wireguard_peer.sh script):
     -e, --endpoint ADDR   Address used by peer to find the "server"
                               If omitted, defaults to: "$endpoint"
     -k, --keepalive KEEP  PersistentKeepalive value to be used by the peers
                               If omitted, defaults to 0
     -a, --allowedips ADDR Network subnets to be routed through the VPN connection
                               Multiple entries will be appended
                               If omitted, defaults to "$allowedips"
   Script options:
     -h, --help            Show this help message and exit
     -v, --verbose         Increase the verbosity of the output
     --dry-run             Do a dry run, dont change any files

   For the pre/post-up/down parameters, this script supports the following symbolics:
     %p - This will changed to the PORT value
     %4 - This will be changed to the server's IPv4 address
     %6 - This will be changed to the server's IPv6 address

HEREDOC
  depth="${depth:1}"; return
}

function valid_ipv4() {
  _verbose $trace "function: $depth${FUNCNAME[0]}"; depth=" $depth"
  local  ip=$1
  local  stat=1

  local  OIFS=$IFS
  IFS='/'
  local  ip=($ip)
  _verbose $debug "$depth\$1     = \"$1\""
  _verbose $debug "$depth\$ip[0] = \"${ip[0]}\""
  _verbose $debug "$depth\$ip[1] = \"${ip[1]}\""
  if [[ ${ip[1]} =~ ^[0-9]{0,2}$ && ${ip[1]} -eq "" || ${ip[1]} -le 32 ]]; then
    if [[ ${ip[0]} =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
      IFS='.'
      ip=(${ip[0]})
      [[ ${ip[0]} -le 255 && ${ip[1]} -le 255 && ${ip[2]} -le 255 && ${ip[3]} -le 255 ]]
      stat=$?
    fi
  fi
  IFS=$OIFS
  _verbose $debug "$depth\$stat:  = \"$stat\""
  depth="${depth:1}"; return $stat
}

function valid_ipv6() {
  _verbose $trace "function: $depth${FUNCNAME[0]}"; depth=" $depth"
  local stat
  local regex1='^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$'
  local regex2='::.+::'
  local regex3=':::'
  local regex4='^[0-9]{0,3}$'
  local OIFS="$IFS"
  IFS="/"
  local ip=($1)
  IFS="$OIFS"
  _verbose $debug "$depth\$1     = \"$1\""
  _verbose $debug "$depth\$ip[0] = \"${ip[0]}\""
  _verbose $debug "$depth\$ip[1] = \"${ip[1]}\""
  [[  ${ip[0]} =~ $regex1 && ! ${ip[0]} =~ $regex2 && ! ${ip[0]} =~ $regex3  ]] && [[  ${ip[1]} =~ $regex4 && ${ip[1]} -eq "" || ${ip[1]} -le 128 ]] && stat=0 || stat=1
#  stat=$?
  _verbose $debug "$depth\$stat:  = \"$stat\""
  depth="${depth,1}"; return $stat
}

function  get_options()
{
  _verbose $trace "function: $depth${FUNCNAME[0]}"; depth=" $depth"

  local err_sw=0
  local my_ips=""

  get_defaults
  if [ $1 != 0 ] ; then echo "Error in command line arguments." >&2 ; usage; exit 12 ; fi

  eval set -- "$OPTS"

  while true; do
    case "$1" in
      -i | --interface ) interface="$2"; shift 2 ;;
      -D | --directory ) wireguard_server_dir="$2"; shift 2 ;;
      -4 | --ipv4 ) ipv4="$2"; shift 2 ;;
      -6 | --ipv6 ) ipv6="$2"; shift 2 ;;
      -p | --port ) listenport="$2"; shift 2 ;;
      -d | --dns ) dns="$dns,$2"; shift 2 ;;
      -m | --mtu ) mtu="$2"; shift 2 ;;
      -s | --save ) saveconfig="true"; shift ;;
           --postup ) postup="$postup;$2"; shift 2 ;;
           --postdown ) postdown="$postdown;$2"; shift 2 ;;
           --preup ) preup="$preup;$2"; shift 2 ;;
           --predown ) predown="$predown;$2"; shift 2 ;;
      -e | --endpoint ) endpoint="$2"; shift 2 ;;
      -k | --keepalive ) keepalive="$2"; shift 2 ;;
      -a | --allowedips ) my_ips="$my_ips,$2"; shift 2;;
      -t | --table ) table="$2"; shift 2;;
      -h | --help ) usage; exit; ;;
      -v | --verbose ) verbose=$((verbose + 1)); if [[ "$verbose" == "$simple" ]];then _verbose $simple  "Called via: \"$0 $orig_opts\"\n$(sha1sum $fullname | cut -d ' ' -f1)"; fi ;  shift ;;
      --dry-run ) dryrun=y; shift ;;
      -- ) shift; break ;;
      * ) break ;;
    esac
  done

  [[ -n $postup ]] && postup=${postup:1}
  [[ -n $preup ]] && preup=${preup:1}
  [[ -n $postdown ]] && postdown=${postdown:1}
  [[ -n $predown ]] && predown=${predown:1}
  [[ -n $dns ]] && dns=${dns:1}
  [[ -n $my_ips ]] && allowedips=${my_ips:1}


  _verbose $simple "   interface:            \"$interface\""
  _verbose $simple "   wireguard_server_dir: \"$wireguard_server_dir\""
  _verbose $simple "   ipv4:                 \"$ipv4\""
  _verbose $simple "   ipv6:                 \"$ipv6\""
  _verbose $simple "   listenport:           \"$listenport\""
  _verbose $simple "   dns:                  \"$dns\""
  _verbose $simple "   mtu:                  \"$mtu\""
  _verbose $simple "   saveconfig:           \"$saveconfig\""
  _verbose $simple "   postup:               \"$postup\""
  _verbose $simple "   postdown:             \"$postdown\""
  _verbose $simple "   preup:                \"$preup\""
  _verbose $simple "   predown:              \"$predown\""
  _verbose $simple "   endpoint:             \"$endpoint\""
  _verbose $simple "   keepalive:            \"$keepalive\""
  _verbose $simple "   table:                \"$table\""
  _verbose $simple "   allowedips:           \"$allowedips\""
  _verbose $simple "   verbose:              \"$verbose\""
  _verbose $simple "   dryrun:               \"$dryrun\""

  wireguard_server_conf="$wireguard_server_dir/$interface.conf"

  if [[ ! -z "$@" ]]; then
     echo "   Unknown parameters were found: $@"
     err_sw=8
  fi

  if [[ ! -d $wireguard_server_dir ]]; then
    echo "Error: Wireguard configuration directory doesn't exist: \"$wireguard_server_dir\""
    err_sw=8
  elif [[ -f $wireguard_server_conf ]]; then
    echo "Error: Wireguard configuration file already exists: \"$wireguard_server_conf\""
    err_sw=8
  fi

  local iplist
  local _ip
  local v_ip4
  local v_ip6

  valid_ipv4 $ipv4
  v_ip4="$?"
  if [[ $v_ip4 != 0 || ! $ipv4 =~ ./. ]]; then
    echo "Error: IPv4 address is invalid: \"$ipv4\""
    err_sw=8
  fi

  valid_ipv6 $ipv6
  v_ip6="$?"
  if [[ $v_ip6 != 0 || ! $ipv6 =~ ./. ]]; then
    echo "Error: IPv6 address is invalid: \"$ipv6\""
    err_sw=8
  fi

  iplist=$(tr ',' ' ' <<< "$allowedips")
  iplist=($iplist)
  for _ip in "${iplist[@]}"; do
    valid_ipv4 $_ip
    v_ip4="$?"
    valid_ipv6 $_ip
    v_ip6="$?"
    if [[ "$v_ip4" == "1" && "$v_ip6" == "1" || ! $_ip =~ ./. ]]; then
      echo "Error: IP address in --allowedips is invalid: \"$_ip\""
      err_sw=8
    fi
  done

  iplist=$(tr ',' ' ' <<< "$dns")
  iplist=($iplist)
  for _ip in "${iplist[@]}"; do
    valid_ipv4 $_ip
    v_ip4="$?"
    valid_ipv6 $_ip
    v_ip6="$?"
    if [[ "$v_ip4" == "1" && "$v_ip6" == "1" || $_ip =~ ./. ]]; then
      echo "Error: IP address in --dns is invalid: \"$_ip\""
      err_sw=8
    fi
  done

  [[ $err_sw != 0 ]] && exit $err_sw

  depth="${depth:1}"; return
}

function init_interface_var() {
  _verbose $trace "function: $depth${FUNCNAME[0]}"; depth=" $depth"
  int_privatekey=""
  int_publickey=""
  int_listenport=""
  int_fwmark=""
  int_address=""
  int_dns=""
  int_mtu=""
  int_table=""
  int_preup=""
  int_postup=""
  int_predown=""
  int_postdown=""
  int_saveconfig=""
  int_endpoint=""
  int_persistentkeepalive=""
  int_allowedips=""
  depth="${depth:1}"; return
}

## Main line routine ##

# initialize variables
progname=$(basename $0)
fullname=$(realpath $0)
verbose=0; depth=""

simple=1
trace=2
debug=3
chatty=4

orig_opts="$@"
OPTS=$(getopt -o "i:D:4:6:p:d:m:e:k:a:t:shv" --long "interface:,directory:,ipv4:,ipv6:,port:,dns:,mtu:,postup:,postdown:,preup:,predown:,endpoint:,keepalive:,allowedips:,table:,save,help,verbose,dry-run" -n "$progname" -- "$@")
get_options "$?"

# The rest of your script below

int_line=()


int_privatekey=$(wg genkey)

OIFS=$IFS

int_line+=( "## Wireguard Server: $interface" )
int_line+=( "[Interface]" )
int_line+=( "PrivateKey = $int_privatekey" )
[[ -n $ipv6 ]] && int_line+=( "Address = $ipv6" )
[[ -n $ipv4 ]] && int_line+=( "Address = $ipv4" )
int_line+=( "ListenPort = $listenport" )

IFS=","
for word in $dns; do
  int_line+=( "DNS = $word" )
done
[[ -n $mtu ]] && int_line+=( "MTU = $mtu" )
[[ -n $table ]] && int_line+=( "Table = $table" )

IFS=";"
for word in $preup; do
  newword=${word//%p/$listenport}
  newword=${newword//%4/$ipv4}
  newword=${newword//%6/$ipv6}
  int_line+=( "PreUp = $newword" )
done
for word in $postup; do
  newword=${word//%p/$listenport}
  newword=${newword//%4/$ipv4}
  newword=${newword//%6/$ipv6}
  int_line+=( "PostUp = $newword" )
done
for word in $predown; do
  newword=${word//%p/$listenport}
  newword=${newword//%4/$ipv4}
  newword=${newword//%6/$ipv6}
  int_line+=( "PreDown = $newword" )
done
for word in $postdown; do
  newword=${word//%p/$listenport}
  newword=${newword//%4/$ipv4}
  newword=${newword//%6/$ipv6}
  int_line+=( "PostDown = $newword" )
done

int_line+=( "SaveConfig = $saveconfig" )
int_line+=( "#EndPoint = $endpoint" )
[[ -n $keepalive ]] && int_line+=( "#PersistentKeepalive = $keepalive" )

IFS=","
for word in $allowedips; do
  int_line+=( "#AllowedIPs = $word" )
done
int_line+=( "#" )

IFS=$OIFS

intfile=""
for line in "${int_line[@]}"; do
  intfile="$intfile\n$line"
done

intfile=${intfile:2}

[[ $dryrun == "y" ]] && echo -e  $intfile || echo -e $intfile >$wireguard_server_conf

exit 0