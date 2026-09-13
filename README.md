# TrueNAS for Omarchy

TrueNAS health on the Omarchy bar: pool status and capacity, active alerts,
disk temperatures, apps, replication and shares, with a popout for the detail
and desktop notifications when something degrades.

Run `truenasctl login` once to point the plugin at your NAS and store the API
key at mode 600. After that the bar and popout read the state the poller writes;
fuller documentation lands once the plugin is finished.
