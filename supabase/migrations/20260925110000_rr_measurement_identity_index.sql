-- Support the existing RR measurement lookup without changing packet identity or conflict handling.
begin;

create index noop_rr_packet_provenance_measurement_lookup
  on public.noop_rr_packet_provenance(user_id,device_id,"sensorTs","recordIndex");

commit;
