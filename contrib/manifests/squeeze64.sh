#!/bin/sh


if [ ! -f /etc/apt/sources.list.d/backports.list ] ; then
  echo "deb http://backports.debian.org/debian-backports squeeze-backports main contrib non-free" > /etc/apt/sources.list.d/backports.list
fi

# if [ ! -f /etc/apt/sources.list.d/sid.list ] ; then
#   echo "deb http://mirrors.kernel.org/debian/ sid main" > /etc/apt/sources.list.d/sid.list
# fi

apt-get update
apt-get -y install erlang-nox #build-essential debhelper lintian
# apt-get -y install rebar build-essential


