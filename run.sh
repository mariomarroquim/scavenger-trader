#!/bin/bash

pkill ruby 2>/dev/null || true

nohup setsid ruby scavenger_trader.rb &>/dev/null &
