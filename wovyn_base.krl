ruleset wovyn_base {
   meta {
      use module io.picolabs.subscription alias subs
      use module temperature_store
      shares global_state, private_state, get_my_seen, get_my_unique_id, get_violated_counter
   }

   global {
      global_state = function() {
         ent:global_state
      }
      private_state = function() {
         ent:private_state
      }

      get_my_seen = function() {
         ent:global_state.map((function(v,k){
            v.keys().map((function(inner_v){inner_v.split(":")[1].as("Number")})).sort("ciremun").head()
          }))
      }

      get_my_unique_id = function() {
         ent:unique_id
      }

      get_temperature = function() {
         ent:temperatures
      }

      get_violated_counter = function() {
         ent:violated_sensor_count
      }

      get_map_operations = function() {
         ent:map_operations
      }
      get_private_operation_state = function() {
         ent:private_operation_state
      }
   }

   rule intialization {
      select when wrangler ruleset_installed where event:attrs{"rids"} >< meta:rid
      fired {
         ent:unique_id := random:uuid()
         ent:sequence_num := 0
         ent:global_state := {}
         ent:private_state := {}
         ent:schedule_id := ""
         ent:cron := <<  0/10 * * * * * >>
         ent:violated_sensor_count := 0
         ent:map_operations := {}
         ent:current_violated := false
         ent:private_operation_state := {} 
      }
   }

   rule collect_temperatures {
      select when wovyn new_temperature_reading
      pre {
         message_id = ent:unique_id + ":" + ent:sequence_num.as("String")
      }
      always {
         ent:temperatures := ent:temperatures.append({"temperature": event:attrs{"temperature"}, "timestamp": event:time})
         ent:global_state{[ent:unique_id, message_id]} := {
            "MessageID": message_id,
            "SensorID": ent:unique_id,
            "Temperature": event:attrs{"temperature"},
            "Timestamp": event:time
         }
         ent:sequence_num := ent:sequence_num + 1


         raise wovyn event "violated_temp"
            if (event:attrs{"temperature"} > 50);
         raise woyvn event "non_violated_temp"
            if (event:attrs{"temperature"} <= 50);
      }
   }

   // 1. violated -> +1 to the counter
   rule violated_temp {
      select when wovyn violated_temp
      if not ent:current_violated then noop() 
      fired {
         ent:map_operations{random:uuid()} := 1
         ent:violated_sensor_count := ent:violated_sensor_count+1
         ent:current_violated := true
      }
   }

   rule non_violated_temp {
      select when wovyn non_violated_temp
      if ent:current_violated then noop()
      fired {
         ent:map_operations{random:uuid()} := -1
         ent:violated_sensor_count := ent:violated_sensor_count-1
         ent:current_violated := false
      }
   }

   rule end_schedule {
      select when end heartbeat
      schedule:remove(ent:schedule_id)
   }

   rule start_schedule {
      select when wake heartbeat
      always {
         schedule gossip event "heartbeat"
         repeat <<  0/5 * * * * * >> attributes {} setting(id);
         ent:schedule_id := id
      }
   }
   

   rule gossip {
      select when gossip heartbeat
      pre {
         flip = random:integer(3) // 0 rumor, 1 seen
      }

      always {
         raise send event "rumor" if (flip == 0)
         raise send event "seen_m" if (flip == 1)
         raise send event "counter_rumor" if (flip == 2)
         raise send event "counter_seen" if (flip == 3)
      }
   }

   rule send_rumor {
      select when send rumor
      pre {
         my_seen = get_my_seen() 
         // Find which subscriber to send
         receiving_tx = ent:private_state.filter(function(other_pico_seen,other_pico_tx){
            my_seen.filter(function(seq_num, sensor_id){
               other_pico_seen{sensor_id}.defaultsTo(-1) < seq_num
            }).length()>0
         }).keys().head()
         // Find which message to send 
         other_pico_has_seen = ent:private_state{receiving_tx}
         longer_sequence = my_seen.filter(function(seq_num, sensor_id){
            other_pico_has_seen{sensor_id}.defaultsTo(-1) < seq_num
         }) // a map of sensor_id to num_info(sequnece_num)
         message_sender = longer_sequence.keys().head()
         seq = other_pico_has_seen{message_sender}.defaultsTo(-1) + 1
         
         rumor_message = ent:global_state{[message_sender, message_sender+":"+seq.as("String")]}
      }

      if receiving_tx != null then
         // Find which one to send
         event:send({ 
            "eci": receiving_tx, 
            "domain":"gossip", "name":"rumor",
            "attrs": {
              "rumor_message": rumor_message
            }
         })

      always {
         ent:private_state{[receiving_tx, message_sender]} := seq
      }
   }

   rule react_rumor {
      select when gossip rumor
      pre {
         rumor_message = event:attrs{"rumor_message"}
         message_id = rumor_message{"MessageID"}
         sensor_id = rumor_message{"SensorID"}
      }
      always {
         ent:global_state{[sensor_id, message_id]} := rumor_message
      }
   }

   rule send_counter_rumor {
      select when send counter_rumor
      pre {//v an array of oids other pico has seen
         // k is tx_channel
         confirm = "test".klog()
         sensor_map = ent:private_operation_state.klog("private_state").filter(function(v,k){ent:map_operations.klog("operations").keys().difference(v).klog("diff").length() > 0}).klog() //map_operation: ours 
         sensor_map_len = sensor_map.keys().klog()
         random_tx_to_send = sensor_map.keys()[random:integer(sensor_map_len)].klog()

         oid_diffs = ent:map_operations.keys().difference(sensor_map{random_tx_to_send})[0].klog()
         
      }

      event:send({ 
         "eci": random_tx_to_send, 
         "domain":"gossip", "name":"counter_rumor",
         "attrs": {
           "rumor_message": {
            "oid": oid_diffs,
            "operation": ent:map_operations{oid_diffs}
           } 
         }
      })

      always {
         ent:private_operation_state{random_tx_to_send} := ent:private_operation_state{random_tx_to_send}.append(oid_diffs)
      }
   }

   rule react_counter_rumor {
      select when gossip counter_rumor
      pre {
         oid = event:attrs{"rumor_message"}{"oid"}
         operation = event:attrs{"rumor_message"}{"operation"}
      }
      if not(ent:map_operations >< oid) then noop()
      
      fired {
         ent:map_operations{oid} := operation
         ent:violated_sensor_count := ent:violated_sensor_count + operation
      }
   }
   // Send my private state to others
   rule send_seen {
      select when send seen_m
         foreach subs:established() setting(subs, i)
      event:send({ 
           "eci": subs{"Tx"}, 
           "domain":"gossip", "name":"seen_m",
           "attrs": {
             "seen_message": get_my_seen(),
             "Tx": subs{"Rx"},
           }
         })
   }
   rule react_seen {
      select when gossip seen_m
      pre {
         seen_message = event:attrs{"seen_message"}
         tx_channel = event:attrs{"Tx"}
      }
      always {
         ent:private_state{tx_channel} := seen_message
      }
   }

   
   rule send_counter_seen {
      select when send seen_m
      foreach subs:established() setting(subs, i)
      event:send({ 
        "eci": subs{"Tx"}, 
        "domain":"gossip", "name":"counter_seen",
        "attrs": {
          "operations": ent:map_operations.keys(),
          "Tx": subs{"Rx"},
        }
      })
   }

   rule react_counter_seen {
      select when gossip counter_seen
      pre {
         operations = event:attrs{"operations"}
         tx_channel = event:attrs{"Tx"}
      }
      always {
         ent:private_operation_state{tx_channel} := operations
      }
   }

   rule clear_counter_state {
      select when testing empty_counter_seen
      always {
         ent:private_operation_state := {}
         ent:violated_sensor_count := 0
         ent:map_operations := {}
         ent:current_violated := false
      }
   }

   rule remove_all_state {
      select when gossip remove_state
      always {
         ent:sequence_num := 0
         ent:global_state := {}
         ent:private_state := {}
         ent:private_operation_state := {}
         ent:violated_sensor_count := 0
         ent:map_operations := {}
         ent:current_violated := false 
      }
   }
}