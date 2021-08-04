#!/bin/bash

# initialize variables
wireguard_server_dir="/etc/wireguard"
wireguard_peer_dir="$wireguard_server_dir/peers"
progname=$(basename $0)
fullname=$(realpath $0)
err_sw=0

verbose=0
simple=1
trace=2
debug=3
chatty=4
depth=""

dryrun=n
peer=""
interface="wg0"
add_peer=0
delete_peer=0
qrcode_peer=0
show_peer=0
list_peers=0
global="0.0.0.0/5,8.0.0.0/7,11.0.0.0/8,12.0.0.0/6,16.0.0.0/4,32.0.0.0/3,64.0.0.0/2,128.0.0.0/3,160.0.0.0/5,168.0.0.0/6,172.0.0.0/12,172.32.0.0/11,172.64.0.0/10,172.128.0.0/9,173.0.0.0/8,174.0.0.0/7,176.0.0.0/4,192.0.0.0/9,192.128.0.0/11,192.160.0.0/13,192.169.0.0/16,192.170.0.0/15,192.172.0.0/14,192.176.0.0/12,192.192.0.0/10,193.0.0.0/8,194.0.0.0/7,196.0.0.0/6,200.0.0.0/5,208.0.0.0/4,2000::/3"

# use getopt and store the output into $OPTS
# note the use of -o for the short options, --long for the long name options
# and a : for any option that takes a parameter
orig_opts="$@"
OPTS=$(getopt -o "p:i:adtrqslLhvP:D:A:" --long "peer:,interface:,add,delete,disallow,reallow,qrcode,show,list,listall,help,verbose,dry-run,peers:,directory:,allowedips:" -n "$progname" -- "$@")
if [ $? != 0 ] ; then echo "Error in command line arguments." >&2 ; usage; exit 12 ; fi

# functions
function usage()
{
   _verbose $trace "function: $depth${FUNCNAME[0]}"; depth=" $depth"
   cat << HEREDOC

   Usage: $progname --peer PEER_NAME [--interface DEV] [--add|--delete|--disallow|--reallow] [--qrcode] [--show] [--list] [--listall] [--help] [--verbose] [--dry-run]

   arguments:
     -p, --peer PEER_NAME  The name of the peer (required)
     -i, --interface DEV   Interface to update:
                               If omitted, defaults to $interface
     -a, --add             Add a new peer
     -d, --delete          Ddelete an existing peer
     -q, --qrcode          Display the QR code for a peer's configuration file
     -s. --show            Show the peer's configuration file
     -l, --list            List peers for the interface
     -D, --directory       Wireguard configuration directory for "server"
                               If omitted, defaults to $wireguard_server_dir
     -P, --peers           Wireguard configuration directory for peers
                               If omitted, defaults to $wireguard_peer_dir
     -A, --allowedips IPs  Override #AllowedIPs in interface file
                              Either a list of IP masks (multple uses will append)
                              or literal:
                                  ALL    = Forces all activity through VPN
                                            further uses of --allowedips ignored
                                  GLOBAL = Only forces global addresses through VPN
                                            further uses of --allowedips will append
                                  VPN    = Allows VPN assigned nets through VPN
                                            further uses of --allowedips will append
     -h, --help            Show this help message and exit
     -v, --verbose         Increase the verbosity of the output
     --dry-run             Do a dry run, dont change any files

     The --add, --delete and --list parameters are mutually exclusive

HEREDOC
  depth="${depth:1}"
}

function _verbose() {
  if (( $verbose >= $1 )); then
    echo -e "$2"
  fi
}


function  get_options()
{
  _verbose $trace "function: $depth${FUNCNAME[0]}"; depth=" $depth"
  eval set -- "$OPTS"

  while true; do
    case "$1" in
      -h | --help ) usage; exit; ;;
      -p | --peer ) peer="$2"; shift 2 ;;
      -i | --interface ) interface="$2"; shift 2 ;;
      -a | --add ) add_peer=1; shift ;;
      -d | --delete ) delete_peer=1; shift ;;
      -q | --qrcode ) qrcode_peer=1; shift ;;
      -s | --show ) show_peer=1; shift ;;
      -l | --list ) list_peers=1; shift ;;
      -D | --directory ) wireguard_server_dir="$2"; shift 2 ;;
      -P | --peers ) wireguard_peer_dir="$2"; shift 2 ;;
      -A | --allowedips ) case "$2" in
                            ALL    ) my_ips=",0.0.0.0/0,::/0" ;;
                            GLOBAL ) my_ips="$my_ips,$global" ;;
                            VPN    ) my_ips="$my_ips,%VPN" ;;
                            *      ) my_ips="$my_ips,$2" ;;
                          esac;
                          shift 2 ;;
      --dry-run ) dryrun=y; shift ;;
      -v | --verbose ) verbose=$((verbose + 1)); if [[ "$verbose" == "$simple" ]];then _verbose $simple  "Called via: \"$0 $orig_opts\"\n$(sha1sum $fullname | cut -d ' ' -f1)"; fi ;  shift ;;
      -- ) shift; break ;;
      * ) break ;;
    esac
  done

  [[ ! -z "$my_ips" ]] && my_ips="${my_ips:1}"

  if (( $verbose >= $trace )); then

     # print out all the parameters we read in
     cat <<EOM
   verbose:       $verbose
   dryrun:        $dryrun
   peer:          $peer
   interface:     $interface
   add_peer:      $add_peer
   delete_peer:   $delete_peer
   qrcode_peer:   $qrcode_peer
   show_peer:     $show_peer
   list_peers:    $list_peers
   my_ips:        $my_ips

EOM
  fi

  if [[ ! -z "$@" ]]; then
     echo "   Unknown parameters were found: $@"
     err_sw=8
  fi

  if [[ $list_peers == 1 ]]; then
     if (( ($add_peer + $delete_peer + $qrcode_peer + $show_peer > 0) )); then
        echo "   When list peers, you may not add, delete, show, or produce a QR code of a peer"
        err_sw=8
     fi
  elif (( ($add_peer + $delete_peer) > 1 )); then
     echo "   You may not add and delete a peer in a single operation"
     err_sw=8
  elif (( ($add_peer + $delete_peer + $qrcode_peer + $show_peer) == 0 )); then
     echo "   No activity requested."
     err_sw=4
  elif (( ($qrcode_peer + $show_peer > 0) && $delete_peer == 1 )); then
     echo "   When deleting a peer, you may not also request its QR code or configuration file"
     err_sw=8
  elif [[ -z "$peer" ]]; then
     echo "   Missing required parameter -p/--peer"
     err_sw=8
  fi

  interface_file="$wireguard_server_dir/$interface.conf"
  _verbose $debug "interface_file: \"$interface_file\""
  peer_file="$wireguard_peer_dir/${interface}_$peer.conf"
  _verbose $debug "peer_file: \"$peer_file\""

  if [[ -d $interface_file ]]; then
     echo "   The interface file is a directory: $interface"
     err_sw=8
  elif [[ ! -f $interface_file ]]; then
     echo "   Unable to find interface file: $interface_file"
     err_sw=8
  fi

  if [[ -f $peer_file ]]; then
    if [[ $add_peer == "1" ]]; then
      echo "    Error: Peer file, \"$peer_file\" already exists"
      err_sw=8
    fi
  elif [[ ! -d $wireguard_peer_dir ]]; then
    if [[ -f $wireguard_peer_dir ]]; then
      echo "    Error: Peer direction, \"$wireguard_peer_dir\" is not a directory"
      err_sw=8
    elif [[ "$dryrun" == "n" ]]; then
      mkdir -p $wireguard_peer_dir
      chmod 755 $wireguard_peer_dir
    fi
  fi

  case $err_sw in
     4) _verbose $chatty "   Exiting with warning"
        exit 4;;
     8) _verbose $chatty "   Exiting with error"
        exit 8;;
     0) ;;
     *) _verbose $chatty "   Exiting with unknown issue: $err_sw "
        exit $err_sw ;;
  esac
  depth="${depth:1}"
}

function init_interface_var() {
  _verbose $trace "function: $depth${FUNCNAME[0]}"; depth=" $depth"
  int_privatekey=""
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
  fnd_int=0
  depth="${depth:1}"
  return
}

function save_interface_val() {
  _verbose $trace "function: $depth${FUNCNAME[0]}"; depth=" $depth"
  case ${key_var,,} in
    privatekey ) int_privatekey="$key_val" ;;
    listenport ) int_listenport="$key_val" ;;
    fwmark ) int_fwmark="$key_val" ;;
    address ) int_address="$int_address,$key_val" ;;
    dns ) int_dns="$int_dns, $key_val" ;;
    mtu ) int_mtu="$key_val" ;;
    table ) int_table="$key_val" ;;
    preup ) int_preup="$int_preup;$key_val" ;;
    postup ) int_postup="$int_postup;$key_val" ;;
    predown ) int_predown="$int_predown;$key_val" ;;
    postdown ) int_postdown="$int_postdown;$key_val" ;;
    saveconfig ) int_saveconfig="$key_val" ;;
    \#endpoint ) int_endpoint="$key_val" ;;
    \#persistentkeepalive ) int_persistentkeepalive="$key_val" ;;
    \#allowedips ) int_allowedips="$int_allowedips, $key_val" ;;
  esac
  depth="${depth:1}"
  return
}

function save_interface() {
  _verbose $trace "function: $depth${FUNCNAME[0]}"; depth=" $depth"
  if [[ ! -z $int_address ]]; then
    int_address="${int_address:1}"
  fi
  if [[ ! -z $int_dns ]]; then
    int_dns="${int_dns:2}"
  fi
  if [[ ! -z $int_preup ]]; then
    int_preup="${int_preup:1}"
  fi
  if [[ ! -z $int_postup ]]; then
    int_postup="${int_postup:1}"
  fi
  if [[ ! -z $int_predown ]]; then
    int_predown="${int_predown:1}"
  fi
  if [[ ! -z $int_postdown ]]; then
    int_postdown="${int_postdown:1}"
  fi
  if [[ ! -z $int_allowedips ]]; then
    int_allowedips="${int_allowedips:2}"
  fi
  if [[ ! -z $int_privatekey ]]; then
    int_publickey=$(echo "$int_privatekey" | wg pubkey )
  else
    int_publickey=""
  fi
  _verbose $debug "
  int_privatekey:          \"$int_privatekey\"
  int_publickey:           \"$int_publickey\"
  int_listenport:          \"$int_listenport\"
  int_fwmark:              \"$int_fwmark\"
  int_address:             \"$int_address\"
  int_dns:                 \"$int_dns\"
  int_mtu:                 \"$int_mtu\"
  int_table:               \"$int_table\"
  int_preup:               \"$int_preup\"
  int_postup:              \"$int_postup\"
  int_predown:             \"$int_predown\"
  int_postdown:            \"$int_postdown\"
  int_saveconfig:          \"$int_saveconfig\"
  int_endpoint:            \"$int_endpoint\"
  int_persistentkeepalive: \"$int_persistentkeepalive\"
  int_allowedips:          \"$int_allowedips\""
  depth="${depth:1}"
  return
}

function check_to_save_int() {
  _verbose $trace "function: $depth${FUNCNAME[0]}"; depth=" $depth"
  case "$fnd_int" in
    0 ) echo "Error: \"[Interface]\" block not found"
        exit 12 ;;
    1 ) save_interface
        fnd_int=2 ;;
    * ) ;;
  esac
  fnd_peer=2
  depth="${depth:1}"; return
}

function unset_peer_arrays() {
  max_peer_size=12
  max_ip_size=15
  unset array_peer_name
  unset array_peer_publickey
  unset array_peer_presharedkey
  unset array_peer_allowedips
  depth="${depth:1}"
  return
}

function init_peer_var() {
  _verbose $trace "function: $depth${FUNCNAME[0]}"; depth=" $depth"
  peer_name=""
  peer_publickey=""
  peer_presharedkey=""
  peer_allowedips=""
  fnd_peer=0
  depth="${depth:1}"
  return
}

function save_peer_val() {
  _verbose $trace "function: $depth${FUNCNAME[0]}"; depth=" $depth"
  case ${key_var,,} in
    publickey ) peer_publickey="$key_val" ;;
    presharedkey ) peer_presharedkey="$key_val" ;;
    allowedips ) peer_allowedips="$peer_allowedips, $key_val" ;;
  esac
  depth="${depth:1}"
  return
}

function save_peer() {
  _verbose $trace "function: $depth${FUNCNAME[0]}"; depth=" $depth"
  if [[ ! -z $peer_allowedips ]]; then
    peer_allowedips="${peer_allowedips:2}"
  fi
  peer_cnt=$((peer_cnt + 1))
  array_peer_name[$peer_cnt]="$peer_name"
  array_peer_publickey[$peer_cnt]="$peer_publickey"
  array_peer_presharedkey[$peer_cnt]="$peer_presharedkey"
  array_peer_allowedips[$peer_cnt]="$peer_allowedips"
  [[ ${#peer_name} > $max_peer_size ]] && max_peer_size=${#peer_name}
  [[ ${#peer_allowedips} > $max_ip_size ]] && max_ip_size=${#peer_allowedips}

  _verbose $debug "array_peer_name[$peer_cnt]:         ${array_peer_name[$peer_cnt]}"
  _verbose $debug "array_peer_publickey[$peer_cnt]:    ${array_peer_publickey[$peer_cnt]}"
  _verbose $debug "array_peer_presharedkey[$peer_cnt]: ${array_peer_preshared_key[$peer_cnt]}"
  _verbose $debug "array_peer_allowedips[$peer_cnt]:   ${array_peer_allowedips[$peer_cnt]}"
  _verbose $debug "max_peer_size:                      $max_peer_size"

  init_peer_var
  depth="${depth:1}"
  return
}

function read_interface() {
  _verbose $trace "function: $depth${FUNCNAME[0]}"; depth=" $depth"

  init_interface_var

  unset_peer_arrays
  init_peer_var

  peer_cnt=0
  shopt -s extglob

# while read -r key_var equal_sign key_val; do
  while read -r line; do
     key_var="${line%%=*}";
     key_var="${key_var##*([[:space:]])}";
     key_var="${key_var%%*([[:space:]])}"

     key_val="${line#*=}";
     key_val="${key_val%%\#*}";
     key_val="${key_val##*([[:space:]])}";
     key_val="${key_val%%*([[:space:]])}";
#    key_val="${key_value%%\#*}"
#    line="$key_var $equal_sign $key_val"
    _verbose $debug  "Line: \"$line\""

    _verbose $debug "   key_var: \"$key_var\""
    _verbose $debug "   key_val: \"$key_val\""

    if [[ "${key_var,,}" == "[interface]" ]]; then
      if [[ $fnd_int == 0 ]]; then
        fnd_int=1
      else
        echo "Error: Found second \"[Interface]\" line"
        exit 12
      fi
    elif [[ "$key_var" == "#Begin-peer" ]]; then
      if  (( $fnd_peer != 0 )); then
        echo "Error: Found another \"#Begin-peer\" before \"#End-Peer\""
        exit 12
      fi
      peer_name="$key_val"
      fnd_peer=1
      _verbose $debug "    Peer name: \"$peer_name\""
    elif [[ "${key_var,,}" == "[peer]" ]]; then
      check_to_save_int
    elif [[ "$key_var" == "#End-peer" ]]; then
      save_peer
      fnd_peer=0
      peer_name=""
    elif (( $fnd_int == 1 )); then
      save_interface_val
    elif (( $fnd_peer > 1 )); then
      save_peer_val
    elif [[ "${line:0:1}" == "#" ]]; then
      continue
    else
      echo "Error: Found non-comment line between/before/after sections:\n    \"$line\""
    fi

  done < $interface_file
  check_to_save_int
  [[ $fnd_peer == 1 ]] && save_peer

  depth="${depth:1}"; return
}

function list_all_peers () {
  _verbose $trace "function: $depth${FUNCNAME[0]}"; depth=" $depth"
  peers_listed=0
  p="  "
  _verbose $debug "max_peer_size: \"$max_peer_size\""
  hdg1="$(eval "printf ' %.0s' {1..$max_peer_size}")"
  _verbose $debug "hdg1: \"$hdg1\""
  hdg1="Common-name$hdg1"
  _verbose $debug "hdg1: \"$hdg1\""
  hdg1="${hdg1:0:$max_peer_size}"
  _verbose $debug "hdg1: \"$hdg1\""
  hdg2="$(eval "printf ' %.0s' {1..$max_ip_size}")"
  _verbose $debug "hdg2: \"$hdg2\""
  hdg2="IP Address(es)$hdg2"
  _verbose $debug "hdg2: \"$hdg2\""
  hdg2="${hdg2:0:$max_ip_size}"
  _verbose $debug "hdg2: \"$hdg2\""
  hdg="| No. | $hdg1 | Public-key                                   | $hdg2 |"

  dash1="$(eval "printf '=%.0s' {1..$max_peer_size} | tr '=' '-'")"
  dash2="$(eval "printf '=%.0s' {1..$max_ip_size}   | tr '=' '-'")"
  dashes="+-----+-$dash1-+----------------------------------------------+-$dash2-+"

  echo ""
  echo "$hdg"
  echo "$dashes"

  for (( i=1; i<=$peer_cnt ; i++ )); do
    case $i in
      10 | 100) p=${p:1}
    esac
    peers_listed=$((peers_listed + 1))
    print_name="$(eval "printf ' %.0s' {1..$max_peer_size}")"
    print_name="${array_peer_name[$i]}$print_name"
    print_name="${print_name:0:$max_peer_size}"
    print_ip="$(eval "printf ' %.0s' {1..$max_ip_size}")"
    print_ip="${array_peer_allowedips[$i]}$print_ip"
    print_ip="${print_ip:0:$max_ip_size}"
    echo "| $p$i | $print_name | ${array_peer_publickey[$i]} | $print_ip |"
  done
  echo "$dashes"
  echo "Total peers listed: $peers_listed"
  depth="${depth:1}"
  return  0
}

function delete_a_peer() {
  _verbose $trace "function: $depth${FUNCNAME[0]}"; depth=" $depth"
  if [[ ! -f $peer_file ]]; then
    echo "Warning: \"$peer_file\" does not exist to delete"
  elif [[ "$dryrun" == "n" ]];then
    rm $peer_file
  else
    echo "Proposed action: \"rm $peer_file\""
  fi

  for (( i=1; i<=$peer_cnt ; i++ )); do
    [[ "${array_peer_name[$i]}" == "$peer" ]] && break
  done

  if (( $i > $peer_cnt )); then
    echo "\"$peer\" not in \"$interface_file\""
  elif [[ "$dryrun" == "n" ]]; then
    sed --in-place=.bk.$(date +%Y%m%d-%H%M%S) -E "/^#Begin-peer *= *$peer$/,/^#End-peer *= *$peer$/d" $interface_file
    wg-quick strip $interface_file | wg syncconf $interface /dev/stdin
  else
    echo "Proposed action: \"sed --in-place=.bk.$(date +%Y%m%d-%H%M%S) '/^#Begin-peer *= *$peer/,/^#End-peer *= *$peer/d' $interface_file\""
    echo "Proposed action: \"wg-quick strip $interface_file | wg syncconf $interface /dev/stdin\""
  fi

  depth="${depth:1}"; return 0
}

function add_a_peer() {
  _verbose $trace "function: $depth${FUNCNAME[0]}"; depth=" $depth"

  local _peer_ipv4
  local _peer_ipv6

  for (( i=1; i<=$peer_cnt ; i++ )); do
    [[ "${array_peer_name[$i]}" == "$peer" ]] && break
  done

  if (( $i <= $peer_cnt )); then
    echo "\"$peer\" already exists in \"$interface_file\""
  else
    for (( _peer_node=2; _peer_node<=255; _peer_node++ )); do
      for (( i=1; i<=$peer_cnt ; i++ )); do
        regex="\.[0]{0,2}$_peer_node\/"
        [[ "${array_peer_allowedips[$i]}" =~ $regex ]] && break
      done
      if (( $i > $peer_cnt )); then
        break
      fi
    done
    if (( $_peer_node == 255 )); then
      echo "no nodes available"
      exit 12
    fi

    peer_private_key=$(wg genkey)
    peer_public_key=$(wg pubkey <<<$peer_private_key)
    peer_shared_key=$(wg genpsk)
    [[ $int_address =~ ([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}) ]] && peer_ipv4="${BASH_REMATCH[1]}"
    [[ $peer_ipv4   =~ (^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.) ]]          && peer_ipv4="${BASH_REMATCH[1]}$_peer_node"
    [[ $int_address =~ (([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}) ]]       && peer_ipv6="${BASH_REMATCH[1]}"
    [[ $peer_ipv6   =~ (([0-9a-fA-F]{0,4}:){1,7}) ]]                       && peer_ipv6="${BASH_REMATCH[1]}$_peer_node"

    peer_int=()
    peer_int+="#Begin-peer = $peer\n"
    peer_int+="[Peer]\n"
    peer_int+="PublicKey = $peer_public_key\n"
    peer_int+="PresharedKey = $peer_shared_key\n"
    peer_int+="AllowedIPs = $peer_ipv4/32, $peer_ipv6/128\n"
    peer_int+="#End-peer = $peer"

    _verbose $debug "** Interface section **\n${peer_int[*]}"

    peer_conf=()
    peer_conf+="#Interface = $interface\n"
    peer_conf+="[Interface]\n"
    peer_conf+="PrivateKey = $peer_private_key\n"
    peer_conf+="Address = $peer_ipv4/24\n"
    peer_conf+="Address = $peer_ipv6/64\n"
    peer_conf+="DNS = $int_dns\n"
    peer_conf+="[Peer]\n"
    peer_conf+="PublicKey = $int_publickey\n"
    peer_conf+="Presharedkey = $peer_shared_key\n"
    [[ -n "$my_ips" ]] && peer_conf+="AllowedIPs = ${my_ips//%VPN/$peer_ipv4/24,$peer_ipv6/64}\n" || peer_conf+="AllowedIPs = $int_allowedips\n"
    peer_conf+="Endpoint = $int_endpoint:$int_listenport\n"
    peer_conf+="PersistentKeepalive = $int_persistentkeepalive\n"

    _verbose $debug "** Peer file **\n${peer_conf[*]}"

    if  [[ "$dryrun" == "y" ]]; then
      echo "*** Add to bottom of \"$interface_file:\""
      echo -e "${peer_int[*]}"
      echo
      echo "*** New configration to be saved in \"$peer_file:\""
      echo -e "${peer_conf[*]}"
      echo
    else
      echo -e "${peer_int[*]}" >>$interface_file
      echo -e "${peer_conf[*]}" >$peer_file
      wg-quick strip $interface_file | wg syncconf $interface /dev/stdin
    fi
  fi

  depth="${depth:1}"; return 0
}

## Main line code ##

get_options
read_interface

if (( $add_peer == 1 )); then
   add_a_peer
elif (( $delete_peer == 1 )); then
   delete_a_peer
elif (( $list_peers == 1 )); then
   list_all_peers
fi

if (( $show_peer == 1 )); then
  if [[ -f $peer_file ]]; then
    cat $peer_file
  else
    echo "Peer configuration file does not exist to display:   \"$peer_file\""
  fi
fi

if (( $qrcode_peer == 1 )); then
  if [[ -f $peer_file ]]; then
    qrencode -t ansiutf8 < "$peer_file"
  else
    echo "Peer configuration file does not exist to QR encode: \"$peer_file\""
  fi
fi

exit 0