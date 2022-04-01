ruleset temperature_store {
   meta {
      provides current_temp, temperatures, threshold_violations, inrange_temperatures
      shares current_temp, temperatures, threshold_violations, inrange_temperatures
   }
   
   global {
      current_temp = function() {
         ent:temperatures[0]
      }
      temperatures = function() {
         ent:temperatures
      }

      threshold_violations = function() {
         ent:temperaturesViolated
      }

      inrange_temperatures = function() {
         ent:temperatures.filter(function(temp){
            ent:temperaturesViolated.index(temp) == -1
         })
      }
   }

   rule intialization {
      select when wrangler ruleset_installed where event:attr("rids") >< meta:rid
      fired {
         ent:temperatures := []
         ent:temperaturesViolated := []      }
    }

   
   rule collect_temperatures {
      select when wovyn new_temperature_reading
      always {
         ent:temperatures := ent:temperatures.append({"temperature": event:attrs{"temperature"}, "timestamp": event:attrs{"timestamp"}})
      }
   }

   rule collect_threshold_violations  {
      select when wovyn threshold_violation

      always {
         ent:temperaturesViolated := ent:temperaturesViolated.append({"temperature": event:attrs{"temperature"}, "timestamp": event:attrs{"timestamp"}})
      }
   }

   rule clear_temperatures {
      select when sensor reading_reset

      always {
         clear ent:temperatures
         clear ent:temperaturesViolated
      }

   }
}