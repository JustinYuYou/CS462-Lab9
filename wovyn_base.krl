ruleset wovyn_base {
   meta {
      use module io.picolabs.subscription alias subs
      use module temperature_store
      shares global_state, private_state, get_my_seen, get_my_unique_id, get_cron
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
      
      get_cron = function() {
         ent:cron
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
      }
   }

   // rule process_heartbeat {
   //    select when wovyn heartbeat where event:attrs{"genericThing"} 
   //    fired {
   //       raise wovyn event "new_temperature_reading"
   //          attributes {
   //             "temperature": event:attrs{"genericThing"}{"data"}{"temperature"}[0]{"temperatureF"},
   //             "timestamp": event:time
   //          } 
   //    }
   // }
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
      }
   }

   rule end_schedule {
      select when end heartbeat
      schedule:remove(ent:schedule_id)
   }

   // rule change_schedule {
   //    select when change get_cron
   //    always {
   //       ent:cron := event:attrs{"cron"}
   //       raise end event "heartbeat"
   //       raise wake event "heartbeat"
   //    }
   // }

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
         flip = random:integer(1) // 0 rumor, 1 seen
      }

      if flip == 0 then noop()

      fired {
         raise send event "rumor"
      } else {
         raise send event "seen_m"
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

   // Send my private state to others
   rule send_seen {
      select when send seen_m
         foreach subs:established() setting(subs, i)
      event:send({ 
           "eci": subs{"Tx"}, 
           "domain":"gossip", "name":"seen_m",
           "attrs": {
             "seen_message": get_my_seen(),
             "Tx": subs{"Rx"}
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

   rule remove_all_state {
      select when gossip remove_state
      always {
         ent:sequence_num := 0
         ent:global_state := {}
         ent:private_state := {}      
      }
   }
}