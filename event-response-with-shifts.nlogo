extensions [csv table time pathdir py]

globals
[
  event-data ;data structure storing all demand events output from generator
  event-reference ;data structure storing characteristics of event types - i.e. resource requirements - to be derived in first instance from ONS crime severity scores
  count-completed-events

  ;Globals to keep track of time
  dt
  Shift-1
  Shift-2
  Shift-3

  count-crime-hour

  ;file globals
  event-summary-file
  active-event-trends-file
  active-resource-trends-file
  resource-summary-file
  resource-usage-trends-file

  force-area       ; force area we are sampling
  loading-factor   ; over/undersampling of historic data
]

;Events store demand - the things the police muct respond to
breed [events event]

;Resource store supply the thing police use to respond to demand - each unit nominally represents a single officer
breed [resources resource]


;POLICE RESOURCE VARIABLES
resources-own
[

  current-event ;the id of the event-agent the resource-agent is responding to
  current-event-type ;the type of event the resource-agent is responding to
  current-event-class ; broader crime class

  ;placeholders to allow units of resource to only be able to respond of events of a certain type - currently not used
  resource-type
  resource-roles

  ;status of resource agent
  resource-status ;represents the current state of the resource agent - coded: 0 = off duty, 1 - on duty and available, 2 = on duty and responding to an event
  resource-start-dt ; the date-time when the current job started

  ;resource-hours-required ;count of hours required to respond to current event
  ;resource-end-dt ;calculated end date/time of current event - equates to resource-start-dt + resource-hours-required

  ;records what shift - if any - a resource is working on
  working-shift

  events-completed ;measure of total number of incidents completed

]



;DEMAND EVENT VARIABLES
events-own
[
  eventID ;link back to event data
  current-resource ; the resource agent(s) (can be multiple) - if any - currently repsonding to this event
  event-status ;status of demand event - coded 1 = awaiting supply, 2 = ongoing, 3 = completed
  event-type ;event type in this model - crime type - i.e. aggravated burglary
  event-class ;event broad class - i.e. burglary
  event-MSOA
  event-start-dt ;datetime event came in
  event-response-start-dt ;datetime response to event started
  event-response-end-dt ;when the event will be reconciled calculated once an event is assigned a resource.
  event-resource-counter ;counts the amount of resource hours remaining before an event is finished
  event-paused ; flags wether an event has previoiusly been acted on - this is used if events are passed between resources at shift change
  event-resource-type ; placeholders to allow units of resource to only be able to respond of events of a certain type - currently not used
  event-resource-req-time ;amount of time resource required to repsond to event - drawn from event-reference
  event-resource-req-amount ;number of resource units required to repsond to event - drawn from event-reference
  event-resource-req-total
  event-priority ; placeholder for variable that allows events to be triaged in terms of importance of response

  event-severity ; ONS CSS associated with offence - as passed by crims
  event-suspect ; bool for presence of suspect - as passed by crims

]






;Procedure to check datetime and adjust flags for shifts currently active/inactive
to check-shift

  ;Shifts:
  ;1. 0700 - 1700
  ;2. 1400 - 2400
  ;3. 2200 - 0700

  let hour time:get "hour" dt

  ;Currently no working roster-off solution - what to do when a job is ongoing?

  ;Shift 1
  if hour = 7 [ set Shift-1 TRUE set Shift-3 FALSE roster-on 1 roster-off 3]
  if hour = 17 [ set Shift-1 FALSE  roster-off 1 ]

  ;Shift 2
  if hour = 14 [ set Shift-2 TRUE roster-on 2 ]
  if hour = 0 [ set Shift-2 FALSE roster-off 2]

  ;Shift 3
  if hour = 22 [ set Shift-3 TRUE roster-on 3]


end

; python interface
; get the current time
to-report pytime
  let call "get_time()"
  report py:runresult call
end

; get the current time
to-report pydone
  let call "at_end()"
  report py:runresult call
end

; exchange data with downstream model - f is a blanket loading factor for crime intensity
to-report pycrimes [f]
  let call (word "get_crimes(" f ")")
  report py:runresult call
end


;main setup procedure
to setup

  ;clear stuff
  ca
  reset-ticks

  if demand-events = "CriMS-Interface"
  [
  ; init python session
  py:setup py:python
  py:run "from netlogo_adapter import init_model, get_time, at_end, get_crimes"

  set force-area Force
  set loading-factor 1.0
  ; TODO year/month is hard-coded below
  py:run (word "init_model('" force-area "', "2020", "7")")
  ]

  ;create folder path to store results based on settings
  let path (word "model-output/" demand-events "/resources" number-resources "/rep" replication "/")
  pathdir:create path

  ;setup output files
  set event-summary-file (word path "event-summary-file.csv")
  set active-event-trends-file (word path "active-event-trends-file.csv")
  set active-resource-trends-file (word path "active-resource-trends-file.csv")
  set resource-summary-file (word path "officer-summary-file.csv")
  set resource-usage-trends-file (word path "resource-usage-trends-file.csv")


  ;size the view window so that 1 patch equals 1 unit of resource - world is 50 resources wide - calculate height and resize
  ;let dim-resource-temp (ceiling (sqrt number-resources)) - 1
  let y-dim-resource-temp (number-resources / 10) - 1

  resize-world 0 9 0 y-dim-resource-temp


  ;initialize shift bools
  set Shift-1 false
  set Shift-2 false
  set Shift-3 false

  ; create police resoruce agents - one per patch
  ask n-of number-resources patches
  [
    sprout-resources 1
    [
      set shape "square"
      set color grey
      ifelse Shifts [set resource-status 0] [set resource-status 1]
      set events-completed 0
    ]
  ]

  ;if shfts are turned on split the agents so that the bottom third work shift 1, middle third shift 2, top third shift 3
  if Shifts
  [
    let third-split-unit ((y-dim-resource-temp + 1) / 3)
    ask resources with [ycor >= 0 and ycor <= ((third-split-unit * 1) - 1)  ] [ set working-shift 1]
    ask resources with [ycor > ((third-split-unit * 1) - 1) and ycor <= ((third-split-unit * 2) - 1)] [ set working-shift 2]
    ask resources with [ycor > ((third-split-unit * 2) - 1)] [ set working-shift 3]
  ]

  ;set the global clock
  if event-file-out [start-file-out]


  ;read in the event data


  if demand-events = "CriMS-Interface" [ print "Reading Event Data from CriMS ......" set event-data csv:from-string (pycrimes(loading-factor)) set dt time:create "2020/06/30 22:00" print event-data]
  if demand-events = "Flat-file" [ print "Reading Event Data from flat-file ......" set event-data csv:from-file "input-data/CriMS-Sample.csv" set dt time:create "2020/01/01 7:00" ]

  set event-data remove-item 0 event-data ;remove top (header) row

end









;the main simulation loop
to go-step

  if VERBOSE [print time:show dt "dd-MM-yyyy HH:mm"]

  ;update time and check shift bool
  if Shifts [check-shift]
  set count-crime-hour 0

  ;read in current hour's events
  read-events


  ;assign resources - right now this is written events look for resources where in reality resources should look for events
  ifelse triage-events
  [
    ;rudimentary triage

    ;pickup ongoing jobs that are paused first
    ask events with [event-priority = 1 and event-status = 1 and event-paused = true] [get-resources]
    ;then jobs that have no one
    ask events with [event-priority = 1 and event-status = 1 and event-paused = false] [get-resources]
    ;then jobs that are ongoing but under staffed
    ask events with [event-priority = 1 and event-status = 2 and event-paused = false and (count current-resource) < event-resource-req-amount] [replenish-resources]

    ask events with [event-priority = 2 and event-status = 1 and event-paused = true] [get-resources]
    ask events with [event-priority = 2 and event-status = 1 and event-paused = false] [get-resources]
    ask events with [event-priority = 2 and event-status = 2 and event-paused = false and (count current-resource) < event-resource-req-amount] [replenish-resources]

    ask events with [event-priority = 3 and event-status = 1 and event-paused = true] [get-resources]
    ask events with [event-priority = 3 and event-status = 1 and event-paused = false] [get-resources]
    ask events with [event-priority = 3 and event-status = 2 and event-paused = false and (count current-resource) < event-resource-req-amount] [replenish-resources]

  ]
  [
    ask events with [event-status = 1 and event-paused = true] [get-resources]
    ask events with [event-status = 1] [get-resources]
    ask events with [event-status = 2 and count current-resource < event-resource-req-amount] [get-resources]
  ]


  ;update visualisations - do this after resources have been allocated and before jobs have finished - so that plots reflect actual resource usage 'mid-hour' as it were
  ask resources [  draw-resource-status ]
  update-all-plots

  ;check status of ongoing events so those about to complete can be closed
  ask events with [event-status = 2] [ check-event-status ]

  ;tick by one hour
  increment-time

  ;repeat

end


;increment internal tick clock and date time object - 1 tick = 1 hour
to increment-time
  tick
  set dt time:plus dt 1 "hours"
end









to start-file-out

  file-close-all

  if file-exists? event-summary-file [file-delete event-summary-file]
  file-open event-summary-file
  file-print "eventID,count-resources,event-status,event-type,event-class,event-LSOA,event-start-dt,event-response-start-dt,event-response-end-dt,event-resource-counter,event-resource-type,event-resource-req-time,event-resource-req-amount,event-resource-req-total"

  if file-exists? active-event-trends-file [file-delete active-event-trends-file]
  file-open active-event-trends-file
  file-print "date-time,Anti-social behaviour,Bicycle theft,Burglary,Criminal damage and arson,Drugs,Other crime,Other theft,Possession of weapons,Public order,Robbery,Shoplifting,Theft from the person,Vehicle crime,Violence and sexual offences"

  if file-exists? active-resource-trends-file [file-delete active-resource-trends-file]
  file-open active-resource-trends-file
  file-print "date-time,Anti-social behaviour,Bicycle theft,Burglary,Criminal damage and arson,Drugs,Other crime,Other theft,Possession of weapons,Public order,Robbery,Shoplifting,Theft from the person,Vehicle crime,Violence and sexual offences"

  if file-exists? resource-usage-trends-file [file-delete resource-usage-trends-file]
  file-open resource-usage-trends-file
  file-print "date-time,usage%,events-ongoing,events-waiting,piority1-waiting,piority2-waiting,piority3-waiting"

end

to close-files
  if file-exists? resource-summary-file [file-delete resource-summary-file]
  file-open resource-summary-file
  file-print "resourceID, events-completed"
  ask resources
  [
    file-print (word who "," events-completed)
  ]

  file-close-all
end



; procedure to read in the events for the given time window / tick
to read-events

  ;API DATA FORMAT
  ;0    1           2               3       4                                             5                     6           7
  ;id   MSOA        crime_type      code    description                                   time                  suspect     severity
  ;0    E02004312   vehicle crime   45      Theft from vehicle                            2020-07-01 00:01:00   false       32.92067737
  ;12   E02004313   vehicle crime   48      Theft or unauthorised taking of motor vehicle 2020-07-01 00:16:00   true        128.4294318

  let hour-end FALSE

  if length event-data > 1
  [
    while [not hour-end]
    [
      ;pull the top row from the data
      let temp item 0 event-data

      ;construct a date
      let temp-dt time:create-with-format (item 5 temp) "yyyy-MM-dd HH:mm:ss"

      ;check if the event occurs at current tick - which is one hour window
      ifelse (time:is-between? temp-dt dt (time:plus dt 59 "minutes"))
      [

        ;create an event agent
        create-events 1
        [
          set count-crime-hour count-crime-hour + 1

          ;make it invisible
          set hidden? true

          ;fill in relevant details for event from data
          ;set eventID item 0 temp

          set event-type item 4 temp
          set event-class item 2 temp
          set event-MSOA item 1 temp

          set event-severity item 7 temp
          set event-suspect item 6 temp

          set event-start-dt dt
          set event-status 1 ;awaiting resource
          set event-paused false

          ;get the amount of units/time required to respond to resource from event info

          set event-resource-req-time convert-severity-to-resource-time event-severity event-suspect 1
          set event-resource-req-amount convert-severity-to-resource-amount event-resource-req-time
          set event-priority convert-severity-to-event-priority event-severity

          set event-resource-req-total event-resource-req-amount * event-resource-req-time
          set event-resource-counter event-resource-req-total

        ]

        ;once the event agent has been created delete it from the data file
        set event-data remove-item 0 event-data

        ; get more data from CriMS if we have consumed it all
        if length event-data = 0 and demand-events = "CriMS-Interface" [
          set event-data csv:from-string (pycrimes(loading-factor))
          set event-data remove-item 0 event-data ;remove top (header) row
        ]
      ]
      [
        ; Event belongs to next hour - set hour-end to stop looping
        set hour-end TRUE
      ]
    ]
  ]

end








; color resource agents based on current state - blue for responding - grey for available
to draw-resource-status

  ifelse color-by-priority
  [
  if resource-status = 0 [ set color grey ] ; rostered off
  if resource-status = 1 [ set color white ] ; active & available
  if resource-status = 2
    [
      let tmp-priority [event-priority] of current-event
      if tmp-priority = 1 [set color red]
      if tmp-priority = 2 [set color blue]
      if tmp-priority = 3 [set color yellow]
    ] ; active & on event

  ]
  [
  if resource-status = 0 [ set color grey ] ; rostered off
  if resource-status = 1 [ set color white ] ; active & available
  if resource-status = 2 [ set color blue ] ; active & on event
  ]

end








; Function that calculates number of officers a case will need based on amount of hours required.
to-report convert-severity-to-resource-amount  [ resource-time ]
  ;derive amount of staff required from amount of time required - if more than 8 hours divide up into additional officers
  let mean-amount ceiling (resource-time / 8)
  ;in this 'stupid' case just apply a random poisson to the mean ammount to get the actual amount to return - and make sure it's a positive number with ABS and at least 1 - so that all events require a resource - HACK
  let amount (ceiling random-poisson mean-amount)
  ;show (word resource-time " Hours needed - mean-amount=" mean-amount " -- Actual=" amount)
  report amount
end

; Function that calculates number of hours a case will need based on severity of offence, presence or absense of a suspect (NOT USED), and a weight which allows mainpulation of how much resouce is allocated to particular offences (NOT USED)
to-report convert-severity-to-resource-time [ severity suspect weight ]
  ;divide severity by 50 and round up to int to get mean hours
  let mean-time ceiling (severity / 50)
  let sd-time (severity / 500)
  ;in this 'stupid' case just apply a random normal to that time to get the actual time to return - and make sure it's a positive number with ABS - HACK
  let time abs round random-normal mean-time sd-time
  ;show (word severity " ONS CSS - mean-time=" mean-time " ,sd-time=" sd-time " -- Actual=" time)
  report time
end


; return priority 1,2, or 3 based on severity - should implement THRIVE here
to-report convert-severity-to-event-priority [ severity ]
  let priority 0
  ;if ONS Severity greater than 1000 - Priority 1; 1000 > x > 500 - Priority 2; x < 500 - Priority 3
  ifelse severity >= 1000
  [ set priority 1 ]
  [ ifelse severity >= 500
    [ set priority 2 ]
    [ set priority 3 ]
  ]
  ;show (word severity " ONS CSS - priority=" priority)
  report priority
end







to roster-on [ shift ]

  ;as a shift changes roster on new staff - assumes that each shift has 1/3 of resources active - although there is overlap between shifts

  if VERBOSE [ print (word "Shift " shift " - Rostering on ") ]

  if shift = 1 [ ask resources with [resource-status = 0 and working-shift = 1] [set resource-status 1 set working-shift 1 ]]
  if shift = 2 [ ask resources with [resource-status = 0 and working-shift = 2] [set resource-status 1 set working-shift 2 ]]
  if shift = 3 [ ask resources with [resource-status = 0 and working-shift = 3] [set resource-status 1 set working-shift 3 ]]

end




;to do next - howdo we roster off officers - what happens to events that arecurrently underway - how are they passed on
; A few  options
; Pass events on to specific  other resource agents
;put the events backon the stack (this would require to count amount of time spent on event so to know remaining hours
; continue working until event finishes - this would likely require agents to pick up events based on how much  time they have lefton their shift
to roster-off [ shift ]

  if VERBOSE [ print (word "Shift " shift " - Rostering off") ]  ;" ends - currently there are " count resources with [ working-shift = shift] " working and " count resources with [resource-status = 1 and working-shift = shift] " officers not on a job to be easily rostered off")
    shift-drop-events shift
    ask resources with [working-shift = shift] [end-shift]

end



to end-shift
  set resource-status 0
  set current-event nobody
  set current-event-type ""
  set current-event-class ""
end






to shift-drop-events  [ shift ]
  ; look at all ongoing events
  ask events with [event-status = 2]
  [
    ;drop all units whose shift has just ended from those events
    set current-resource current-resource with [working-shift != shift]
    ;check if that leaves any resource left
    if count current-resource = 0
    [
      ;if not pause the event and set its status back to 1
      set event-status 1
      set event-paused true
      ;print (word self " was paused due to lack of staff - a further " event-resource-counter " are required to complete this event")
    ]
  ]
end








; event procedure that checks whether a currently running event can be closed off
to check-event-status
  ;check when event being responded to should be finshed

  ;alternative - check if no more resource hours are required
  ifelse event-resource-counter = 0
  ;check if the secdeuled event end date/time is now
  ;ifelse time:is-equal event-response-end-dt dt
  [
    ; if it is this cycle - end the event, record that, relinquish resource(s), destroy the event agent
    ask current-resource [ relinquish ]
    ;count completion
    set count-completed-events count-completed-events + 1

    if VERBOSE [print (word "Event complete - " event-type " - Priority=" event-priority ", Event-Arrival=" (time:show event-start-dt "dd-MM-yyyy HH:mm") ", Response-Start=" (time:show event-response-start-dt "dd-MM-yyyy HH:mm") ", Response-Complete=" (time:show dt "dd-MM-yyyy HH:mm") ", Timetaken=" (time:difference-between event-response-start-dt dt "hours") " hours")]

    ;destroy event object

    ;show (word "Job complete")


    ;if the job is complete write its details to the event output file
    if event-file-out
    [
      file-open event-summary-file
      file-print (word
        eventID ","
        count current-resource ","
        event-status ",\""
        event-type "\",\""
        event-class "\","
        event-MSOA ","
        (time:show event-start-dt "dd-MM-yyyy HH:mm") ","
        (time:show event-response-start-dt "dd-MM-yyyy HH:mm")  ","
        (time:show dt "dd-MM-yyyy HH:mm") ","
        event-resource-counter ","
        event-resource-type ","
        event-resource-req-time ","
        event-resource-req-amount ","
        event-resource-req-total
      )
    ]

    ;then destroy the object
    die
  ]
  [
    ;otherwise count the time spent thus far
    set event-resource-counter (event-resource-counter - count current-resource)
    ;show (word "Job ongoing - requires = " event-resource-req-total " --- currently " count current-resource " resources allocated - " event-resource-counter " resource hours remaining")
  ]



end


;
to relinquish

  set events-completed events-completed + 1
  set resource-status 1
  set current-event-type ""
  set current-event-class ""

end





; event procedure to assess if sufficient resources are available to respond to event and if so allocate them to it
to get-resources

  ;check if the required number of resources are available
  if count resources with [resource-status = 1] >= (event-resource-req-amount)
  [
    if VERBOSE [print (word "Officers responding to priority " event-priority " " event-type " event - " event-resource-req-amount " unit(s) required for " event-resource-req-time " hour(s) - TOTAL RESOURCE REQ = " event-resource-req-total)]
    ;link resource to event
    set current-resource n-of event-resource-req-amount resources with [resource-status = 1]

    ;record start and end datetime of response
    if event-paused = false [set event-response-start-dt dt]
    ;set event-response-end-dt time:plus dt (event-resource-req-time) "hours"
    set event-status 2 ; mark the event as ongoing

    ask current-resource
    [
      set current-event myself
      set current-event-type [event-type] of current-event
      set current-event-class [event-class] of current-event
      set resource-status 2
    ]
    set event-paused false
  ]

end




















; event procedure to assess if sufficient resources are available to respond to event and if so allocate them to it
to replenish-resources

  ;check if the required number of resources are available to replenish job
  if count resources with [resource-status = 1] >= (event-resource-req-amount - (count current-resource))
  [
    if VERBOSE [print (word "Adding officers to " event-type " event - " event-resource-req-amount " unit(s) required for " event-resource-req-time " hour(s) - TOTAL RESOURCE REQ = " event-resource-req-total)]

    ;link resource to event
    ;print (word count current-resource " - pre replenish - paused - " event-paused )
    set current-resource (turtle-set current-resource n-of (event-resource-req-amount - (count current-resource)) resources with [resource-status = 1])
    ;print (word count current-resource " - post replenish")

    ;set event-response-end-dt time:plus dt (event-resource-req-time) "hours"
    set event-status 2 ; mark the event as ongoing

    ask current-resource
    [
      ;link event to resource
      set current-event myself
      set current-event-type [event-type] of current-event
      set current-event-class [event-class] of current-event
      set resource-status 2
    ]

  ]

end














;plot update commands
to update-all-plots



  file-open resource-usage-trends-file
  file-print (word (time:show dt "dd-MM-yyyy HH:mm") "," ((count resources with [resource-status = 2] / count resources with [resource-status = 2 or resource-status = 1] ) * 100) "," (count events with [event-status = 2]) "," (count events with [event-status = 1]) "," (count events with [event-status = 1 and event-priority = 1]) "," (count events with [event-status = 1 and event-priority = 2]) "," (count events with [event-status = 1 and event-priority = 3]))





  set-current-plot "Crime"
  set-current-plot-pen "total"
  plot count-crime-hour


  set-current-plot "Count Available Resources"
  set-current-plot-pen "resources"
  plot count resources with [resource-status = 1 or resource-status = 2]


  set-current-plot "Total Resource Usage"
  set-current-plot-pen "Supply"
  plot (count resources with [resource-status = 2] / count resources with [resource-status = 2 or resource-status = 1] ) * 100

  set-current-plot "Count Active Resources"
  set-current-plot-pen "count-active-resources"
  plot (count resources with [resource-status = 2])

  set-current-plot "Events Waiting"
  set-current-plot-pen "waiting-total"
  plot count events with [event-status = 1]
  set-current-plot-pen "waiting-1"
  plot count events with [event-status = 1 and event-priority = 1]
  set-current-plot-pen "waiting-2"
  plot count events with [event-status = 1 and event-priority = 2]
  set-current-plot-pen "waiting-3"
  plot count events with [event-status = 1 and event-priority = 3]


  ;------------------------------------------------------------------------------------------------------------------------------

  ;plotting and recording the amount of events currently being responded to by crime-classes this hour
  set-current-plot "active-events"
  file-open active-event-trends-file
  ;only look at active events
  let current-events events with [event-status = 2]
  let out-string (word (time:show dt "dd-MM-yyyy HH:mm") ",")

  set-current-plot-pen "Anti-social behaviour"
  let x count current-events with [event-class = "Anti-social behaviour"]
  plot x
  set out-string (word out-string x ",")

  set-current-plot-pen "Bicycle theft"
  set x count current-events with [event-class = "Bicycle theft"]
  plot x
  set out-string (word out-string x ",")

  set-current-plot-pen "Burglary"
  set x count current-events with [event-class = "Burglary"]
  plot x
  set out-string (word out-string x ",")

  set-current-plot-pen "Criminal damage and arson"
  set x count current-events with [event-class = "Criminal damage and arson"]
  plot x
  set out-string (word out-string x ",")

  set-current-plot-pen "Drugs"
  set x count current-events with [event-class = "Drugs"]
  plot x
  set out-string (word out-string x ",")

  set-current-plot-pen "Other crime"
  set x count current-events with [event-class = "Other crime"]
  plot x
  set out-string (word out-string x ",")

  set-current-plot-pen "Other theft"
  set x count current-events with [event-class = "Other theft"]
  plot x
  set out-string (word out-string x ",")

  set-current-plot-pen "Possession of weapons"
  set x count current-events with [event-class = "Possession of weapons"]
  plot x
  set out-string (word out-string x ",")

  set-current-plot-pen "Public order"
  set x count current-events with [event-class = "Public order"]
  plot x
  set out-string (word out-string x ",")

  set-current-plot-pen "Robbery"
  set x count current-events with [event-class = "Robbery"]
  plot x
  set out-string (word out-string x ",")

  set-current-plot-pen "Shoplifting"
  set x count current-events with [event-class = "Shoplifting"]
  plot x
  set out-string (word out-string x ",")

  set-current-plot-pen "Theft from the person"
  set x count current-events with [event-class = "Theft from the person"]
  plot x
  set out-string (word out-string x ",")

  set-current-plot-pen "Vehicle crime"
  set x count current-events with [event-class = "Vehicle crime"]
  plot x
  set out-string (word out-string x ",")

  set-current-plot-pen "Violence and sexual offences"
  set x count current-events with [event-class = "Violence and sexual offences"]
  plot x
  set out-string (word out-string x)

  file-print out-string


  ;------------------------------------------------------------------------------------------------------------------------------

  ;plotting and recording the amount of resources devoted to crime-classes this hour
  set-current-plot "resources"
  file-open active-resource-trends-file
  set out-string (word (time:show dt "dd-MM-yyyy HH:mm") ",")

  set-current-plot-pen "Anti-social behaviour"
  set x count resources with [current-event-class = "Anti-social behaviour"]
  plot x
  set out-string (word out-string x ",")

  set-current-plot-pen "Bicycle theft"
  set x count resources with [current-event-class = "Bicycle theft"]
  plot x
  set out-string (word out-string x ",")

  set-current-plot-pen "Burglary"
  set x count resources with [current-event-class = "Burglary"]
  plot x
  set out-string (word out-string x ",")

  set-current-plot-pen "Criminal damage and arson"
  set x count resources with [current-event-class = "Criminal damage and arson"]
  plot x
  set out-string (word out-string x ",")

  set-current-plot-pen "Drugs"
  set x count resources with [current-event-class = "Drugs"]
  plot x
  set out-string (word out-string x ",")

  set-current-plot-pen "Other crime"
  set x count resources with [current-event-class = "Other crime"]
  plot x
  set out-string (word out-string x ",")

  set-current-plot-pen "Other theft"
  set x count resources with [current-event-class = "Other theft"]
  plot x
  set out-string (word out-string x ",")

  set-current-plot-pen "Possession of weapons"
  set x count resources with [current-event-class = "Possession of weapons"]
  plot x
  set out-string (word out-string x ",")

  set-current-plot-pen "Public order"
  set x count resources with [current-event-class = "Public order"]
  plot x
  set out-string (word out-string x ",")

  set-current-plot-pen "Robbery"
  set x count resources with [current-event-class = "Robbery"]
  plot x
  set out-string (word out-string x ",")

  set-current-plot-pen "Shoplifting"
  set x count resources with [current-event-class = "Shoplifting"]
  plot x
  set out-string (word out-string x ",")

  set-current-plot-pen "Theft from the person"
  set x count resources with [current-event-class = "Theft from the person"]
  plot x
  set out-string (word out-string x ",")

  set-current-plot-pen "Vehicle crime"
  set x count resources with [current-event-class = "Vehicle crime"]
  plot x
  set out-string (word out-string x ",")

  set-current-plot-pen "Violence and sexual offences"
  set x count resources with [current-event-class = "Violence and sexual offences"]
  plot x
  set out-string (word out-string x)

  file-print out-string

  ;--------------------------------------------------------------------------------------------------------------------------------------------

  set-current-plot "scatter"
  ;clear-plot
  set-current-plot-pen "Anti-social behaviour"
  plotxy (count events with [event-class = "Anti-social behaviour" and event-status = 2]) (count resources with [current-event-class = "Anti-social behaviour"])
  set-current-plot-pen "Bicycle theft"
  plotxy (count events with [event-class = "Bicycle theft" and event-status = 2]) (count resources with [current-event-class = "Bicycle theft"])
  set-current-plot-pen "Burglary"
  plotxy (count events with [event-class = "Burglary" and event-status = 2]) (count resources with [current-event-class = "Burglary"])
  set-current-plot-pen "Criminal damage and arson"
  plotxy (count events with [event-class = "Criminal damage and arson" and event-status = 2]) (count resources with [current-event-class = "Criminal damage and arson"])
  set-current-plot-pen "Drugs"
  plotxy (count events with [event-class = "Drugs" and event-status = 2]) (count resources with [current-event-class = "Drugs"])
  set-current-plot-pen "Other crime"
  plotxy (count events with [event-class = "Other crime" and event-status = 2]) (count resources with [current-event-class = "Other crime"])
  set-current-plot-pen "Other theft"
  plotxy (count events with [event-class = "Other theft" and event-status = 2]) (count resources with [current-event-class = "Other theft"])
  set-current-plot-pen "Possession of weapons"
  plotxy (count events with [event-class = "Possession of weapons" and event-status = 2]) (count resources with [current-event-class = "Possession of weapons"])
  set-current-plot-pen "Public order"
  plotxy (count events with [event-class = "Public order" and event-status = 2]) (count resources with [current-event-class = "Public order"])
  set-current-plot-pen "Robbery"
  plotxy (count events with [event-class = "Robbery" and event-status = 2]) (count resources with [current-event-class = "Robbery"])
  set-current-plot-pen "Shoplifting"
  plotxy (count events with [event-class = "Shoplifting" and event-status = 2]) (count resources with [current-event-class = "Shoplifting"])
  set-current-plot-pen "Theft from the person"
  plotxy (count events with [event-class = "Theft from the person" and event-status = 2]) (count resources with [current-event-class = "Theft from the person"])
  set-current-plot-pen "Vehicle crime"
  plotxy (count events with [event-class = "Vehicle crime" and event-status = 2]) (count resources with [current-event-class = "Vehicle crime"])
  set-current-plot-pen "Violence and sexual offences"
  plotxy (count events with [event-class = "Violence and sexual offences" and event-status = 2]) (count resources with [current-event-class = "Violence and sexual offences"])

end


to-report equal-ignore-case? [ str1 str2 ]

  if (length str1 != length str2) [ report false ]

  foreach (range length str1) [ i ->
    let c1 (item i str1)
    let c2 (item i str2)
    ; if c1 = c2, no need to do the `to-upper-char` stuff
    if (c1 != c2 and to-upper-char c1 != to-upper-char c2) [
      report false
    ]
  ]
  report true
end

; this only works with a string length 1
to-report to-upper-char [ c ]
  let lower "abcdefghijklmnopqrstuvwxyz"
  let upper "ABCDEFGHIJKLMNOPQRSTUVWXYZ"

  let pos (position c lower)
  report ifelse-value (is-number? pos) [ item pos upper ] [ c ]
end



;Anti-social behaviour
;plot count events with [event-type = "Anti-social behaviour"]
;Bicycle theft
;plot count events with [event-type = "Bicycle theft"]
;Burglary
;plot count events with [event-type = "Burglary"]
;Criminal damage and arson
;plot count events with [event-type = "Criminal damage and arson"]
;Drugs
;plot count events with [event-type = "Drugs"]
;Other crime
;plot count events with [event-type = "Other crime"]
;Other theft
;plot count events with [event-type = "Other theft"]
;Possession of weapons
;plot count events with [event-type = "Possession of weapons"]
;Public order
;plot count events with [event-type = "Public order"]
;Robbery
;plot count events with [event-type = "Robbery"]
;Shoplifting
;plot count events with [event-type = "Shoplifting"]
;Theft from the person
;plot count events with [event-type = "Theft from the person"]
;Vehicle crime
;plot count events with [event-type = "Vehicle crime"]
;Violence and sexual offences
;plot count events with [event-type = "Violence and sexual offences"]









;if event-type = "Anti-social behaviour"
;if event-type = "Bicycle theft"
;if event-type = "Burglary"
;if event-type = "Criminal damage and arson"
;if event-type = "Drugs"
;if event-type = "Other crime"
;if event-type = "Other theft"
;if event-type = "Possession of weapons"
;if event-type = "Public order"
;if event-type = "Robbery"
;if event-type = "Shoplifting"
;if event-type = "Theft from the person"
;if event-type = "Vehicle crime"
;if event-type = "Violence and sexual offences"
;
;
;plot count events with [event-type = "Anti-social behaviour"]
;plot count events with [event-type = "Bicycle theft"]
;plot count events with [event-type = "Burglary"]
;plot count events with [event-type = "Criminal damage and arson"]
;plot count events with [event-type = "Drugs"]
;plot count events with [event-type = "Other crime"]
;plot count events with [event-type = "Other theft"]
;plot count events with [event-type = "Possession of weapons"]
;plot count events with [event-type = "Public order"]
;plot count events with [event-type = "Robbery"]
;plot count events with [event-type = "Shoplifting"]
;plot count events with [event-type = "Theft from the person"]
;plot count events with [event-type = "Vehicle crime"]
;plot count events with [event-type = "Violence and sexual offences"]
@#$#@#$#@
GRAPHICS-WINDOW
205
10
378
316
-1
-1
16.5
1
10
1
1
1
0
1
1
1
0
9
0
17
0
0
1
ticks
30.0

BUTTON
10
15
80
48
NIL
setup\n
NIL
1
T
OBSERVER
NIL
NIL
NIL
NIL
1

SLIDER
395
120
535
153
number-resources
number-resources
60
5000
180.0
60
1
NIL
HORIZONTAL

BUTTON
85
15
175
48
NIL
go-step
T
1
T
OBSERVER
NIL
NIL
NIL
NIL
1

MONITOR
394
219
534
264
Resources Free
count resources with [resource-status = 1]
17
1
11

MONITOR
395
365
535
410
Events - Awaiting
count events with [event-status = 1]
17
1
11

MONITOR
395
412
532
457
Events - Ongoing
count events with [event-status = 2]
17
1
11

MONITOR
395
462
533
507
Events - Completed
count-completed-events
17
1
11

PLOT
905
15
1285
135
Total Resource Usage
time
%
0.0
10.0
0.0
100.0
true
false
"" ""
PENS
"Supply" 1.0 0 -16777216 true "" ""

PLOT
540
262
1285
521
active-events
time
count of events
0.0
10.0
0.0
10.0
true
true
"" ""
PENS
"Anti-social behaviour" 1.0 0 -16777216 true "" ""
"Bicycle theft" 1.0 0 -7500403 true "" ""
"Burglary" 1.0 0 -2674135 true "" ""
"Criminal damage and arson" 1.0 0 -955883 true "" ""
"Drugs" 1.0 0 -6459832 true "" ""
"Other crime" 1.0 0 -1184463 true "" ""
"Other theft" 1.0 0 -10899396 true "" ""
"Possession of weapons" 1.0 0 -13840069 true "" ""
"Public order" 1.0 0 -14835848 true "" ""
"Robbery" 1.0 0 -11221820 true "" ""
"Shoplifting" 1.0 0 -13791810 true "" ""
"Theft from the person" 1.0 0 -13345367 true "" ""
"Vehicle crime" 1.0 0 -8630108 true "" ""
"Violence and sexual offences" 1.0 0 -5825686 true "" ""

BUTTON
85
50
175
83
NIL
go-step
NIL
1
T
OBSERVER
NIL
NIL
NIL
NIL
1

TEXTBOX
15
575
140
652
Shifts:\n1. 0700 - 1700\n2. 1400 - 2400\n3. 2200 - 0700
15
0.0
1

MONITOR
394
15
533
60
Current DateTime
time:show dt \"dd-MM-yyyy HH:mm\"
17
1
11

PLOT
1290
262
1724
782
scatter
count events
count resource
0.0
10.0
0.0
10.0
true
true
"" ""
PENS
"Anti-social behaviour" 1.0 2 -16777216 true "" ""
"Bicycle theft" 1.0 2 -7500403 true "" ""
"Burglary" 1.0 2 -2674135 true "" ""
"Criminal damage and arson" 1.0 2 -955883 true "" ""
"Drugs" 1.0 2 -6459832 true "" ""
"Other crime" 1.0 2 -1184463 true "" ""
"Other theft" 1.0 2 -10899396 true "" ""
"Possession of weapons" 1.0 2 -13840069 true "" ""
"Public order" 1.0 2 -14835848 true "" ""
"Robbery" 1.0 2 -11221820 true "" ""
"Shoplifting" 1.0 2 -13791810 true "" ""
"Theft from the person" 1.0 2 -13345367 true "" ""
"Vehicle crime" 1.0 2 -8630108 true "" ""
"Violence and sexual offences" 1.0 2 -5825686 true "" ""

PLOT
541
526
1286
783
resources
time
resources
0.0
10.0
0.0
10.0
true
true
"" ""
PENS
"Anti-social behaviour" 1.0 0 -16777216 true "" ""
"Bicycle theft" 1.0 0 -7500403 true "" ""
"Burglary" 1.0 0 -2674135 true "" ""
"Criminal damage and arson" 1.0 0 -955883 true "" ""
"Drugs" 1.0 0 -6459832 true "" ""
"Other crime" 1.0 0 -1184463 true "" ""
"Other theft" 1.0 0 -10899396 true "" ""
"Possession of weapons" 1.0 0 -13840069 true "" ""
"Public order" 1.0 0 -14835848 true "" ""
"Robbery" 1.0 0 -11221820 true "" ""
"Shoplifting" 1.0 0 -13791810 true "" ""
"Theft from the person" 1.0 0 -13345367 true "" ""
"Vehicle crime" 1.0 0 -8630108 true "" ""
"Violence and sexual offences" 1.0 0 -5825686 true "" ""

SWITCH
10
500
175
533
VERBOSE
VERBOSE
0
1
-1000

MONITOR
394
267
534
312
Resources Responding
count resources with [resource-status = 2]
17
1
11

SWITCH
10
420
175
453
Shifts
Shifts
0
1
-1000

MONITOR
12
147
177
192
Events in Queue
length event-data
17
1
11

PLOT
1291
15
1720
135
Events Waiting
NIL
NIL
0.0
10.0
0.0
10.0
true
true
"" ""
PENS
"waiting-total" 1.0 0 -16777216 true "" ""
"waiting-1" 1.0 0 -2674135 true "" ""
"waiting-2" 1.0 0 -955883 true "" ""
"waiting-3" 1.0 0 -1184463 true "" ""

SWITCH
10
535
175
568
event-file-out
event-file-out
0
1
-1000

CHOOSER
10
98
180
143
demand-events
demand-events
"CriMS-Interface" "Flat-file"
0

SWITCH
10
455
175
488
triage-events
triage-events
0
1
-1000

MONITOR
396
529
530
574
priority 1 waiting
count events with [event-status = 1 and event-priority = 1]
17
1
11

MONITOR
396
577
530
622
priority 2 waiting
count events with [event-status = 1 and event-priority = 2]
17
1
11

MONITOR
396
629
531
674
priority 3 waiting
count events with [event-status = 1 and event-priority = 3]
17
1
11

PLOT
540
15
900
135
Crime
NIL
NIL
0.0
10.0
0.0
10.0
true
false
"" ""
PENS
"total" 1.0 0 -16777216 true "" ""

BUTTON
10
667
170
702
close files
close-files
NIL
1
T
OBSERVER
NIL
NIL
NIL
NIL
1

SLIDER
10
370
175
403
replication
replication
1
100
1.0
1
1
NIL
HORIZONTAL

MONITOR
394
64
533
109
Shift1-Shift2-Shift3
(word Shift-1 \"-\" Shift-2 \"-\" Shift-3)
17
1
11

PLOT
1291
137
1721
257
paused events
NIL
NIL
0.0
10.0
0.0
10.0
true
false
"" ""
PENS
"default" 1.0 0 -16777216 true "" "plot count events with [event-paused = true]"

PLOT
905
135
1285
255
Count Active Resources
NIL
NIL
0.0
10.0
0.0
10.0
true
false
"" ""
PENS
"count-active-resources" 1.0 0 -16777216 true "" ""

PLOT
541
137
901
257
Count Available Resources
NIL
NIL
0.0
10.0
0.0
10.0
true
false
"" ""
PENS
"resources" 1.0 0 -16777216 true "" ""

SWITCH
10
712
172
745
color-by-priority
color-by-priority
1
1
-1000

CHOOSER
15
200
175
245
Force
Force
"Avon and Somerset" "Bedfordshire" "Cambridgeshire" "Cheshire" "Cleveland" "Cumbria" "Derbyshire" "Devon and Cornwall" "Dorset" "Durham" "Dyfed-Powys" "Essex" "Gloucestershire" "Greater Manchester" "Gwent" "Hampshire" "Hertfordshire" "Humberside" "Kent" "Lancashire" "Leicestershire" "Lincolnshire" "City of London" "Merseyside" "Metropolitan Police" "Norfolk" "North Wales" "North Yorkshire" "Northamptonshire" "Northumbria" "Nottinghamshire" "South Wales" "South Yorkshire" "Staffordshire" "Suffolk" "Surrey" "Sussex" "Thames Valley" "Warwickshire" "West Mercia" "West Midlands" "West Yorkshire" "Wiltshire"
22

INPUTBOX
15
250
175
310
StartDate
2020/7/1
1
0
String

@#$#@#$#@
## WHAT IS IT?

(a general understanding of what the model is trying to show or explain)

## HOW IT WORKS

(what rules the agents use to create the overall behavior of the model)

## HOW TO USE IT

(how to use the model, including a description of each of the items in the Interface tab)

## THINGS TO NOTICE

(suggested things for the user to notice while running the model)

## THINGS TO TRY

(suggested things for the user to try to do (move sliders, switches, etc.) with the model)

## EXTENDING THE MODEL

(suggested things to add or change in the Code tab to make the model more complicated, detailed, accurate, etc.)

## NETLOGO FEATURES

(interesting or unusual features of NetLogo that the model uses, particularly in the Code tab; or where workarounds were needed for missing features)

## RELATED MODELS

(models in the NetLogo Models Library and elsewhere which are of related interest)

## CREDITS AND REFERENCES

(a reference to the model's URL on the web if it has one, as well as any other necessary credits, citations, and links)
@#$#@#$#@
default
true
0
Polygon -7500403 true true 150 5 40 250 150 205 260 250

airplane
true
0
Polygon -7500403 true true 150 0 135 15 120 60 120 105 15 165 15 195 120 180 135 240 105 270 120 285 150 270 180 285 210 270 165 240 180 180 285 195 285 165 180 105 180 60 165 15

arrow
true
0
Polygon -7500403 true true 150 0 0 150 105 150 105 293 195 293 195 150 300 150

box
false
0
Polygon -7500403 true true 150 285 285 225 285 75 150 135
Polygon -7500403 true true 150 135 15 75 150 15 285 75
Polygon -7500403 true true 15 75 15 225 150 285 150 135
Line -16777216 false 150 285 150 135
Line -16777216 false 150 135 15 75
Line -16777216 false 150 135 285 75

bug
true
0
Circle -7500403 true true 96 182 108
Circle -7500403 true true 110 127 80
Circle -7500403 true true 110 75 80
Line -7500403 true 150 100 80 30
Line -7500403 true 150 100 220 30

butterfly
true
0
Polygon -7500403 true true 150 165 209 199 225 225 225 255 195 270 165 255 150 240
Polygon -7500403 true true 150 165 89 198 75 225 75 255 105 270 135 255 150 240
Polygon -7500403 true true 139 148 100 105 55 90 25 90 10 105 10 135 25 180 40 195 85 194 139 163
Polygon -7500403 true true 162 150 200 105 245 90 275 90 290 105 290 135 275 180 260 195 215 195 162 165
Polygon -16777216 true false 150 255 135 225 120 150 135 120 150 105 165 120 180 150 165 225
Circle -16777216 true false 135 90 30
Line -16777216 false 150 105 195 60
Line -16777216 false 150 105 105 60

car
false
0
Polygon -7500403 true true 300 180 279 164 261 144 240 135 226 132 213 106 203 84 185 63 159 50 135 50 75 60 0 150 0 165 0 225 300 225 300 180
Circle -16777216 true false 180 180 90
Circle -16777216 true false 30 180 90
Polygon -16777216 true false 162 80 132 78 134 135 209 135 194 105 189 96 180 89
Circle -7500403 true true 47 195 58
Circle -7500403 true true 195 195 58

circle
false
0
Circle -7500403 true true 0 0 300

circle 2
false
0
Circle -7500403 true true 0 0 300
Circle -16777216 true false 30 30 240

cow
false
0
Polygon -7500403 true true 200 193 197 249 179 249 177 196 166 187 140 189 93 191 78 179 72 211 49 209 48 181 37 149 25 120 25 89 45 72 103 84 179 75 198 76 252 64 272 81 293 103 285 121 255 121 242 118 224 167
Polygon -7500403 true true 73 210 86 251 62 249 48 208
Polygon -7500403 true true 25 114 16 195 9 204 23 213 25 200 39 123

cylinder
false
0
Circle -7500403 true true 0 0 300

dot
false
0
Circle -7500403 true true 90 90 120

face happy
false
0
Circle -7500403 true true 8 8 285
Circle -16777216 true false 60 75 60
Circle -16777216 true false 180 75 60
Polygon -16777216 true false 150 255 90 239 62 213 47 191 67 179 90 203 109 218 150 225 192 218 210 203 227 181 251 194 236 217 212 240

face neutral
false
0
Circle -7500403 true true 8 7 285
Circle -16777216 true false 60 75 60
Circle -16777216 true false 180 75 60
Rectangle -16777216 true false 60 195 240 225

face sad
false
0
Circle -7500403 true true 8 8 285
Circle -16777216 true false 60 75 60
Circle -16777216 true false 180 75 60
Polygon -16777216 true false 150 168 90 184 62 210 47 232 67 244 90 220 109 205 150 198 192 205 210 220 227 242 251 229 236 206 212 183

fish
false
0
Polygon -1 true false 44 131 21 87 15 86 0 120 15 150 0 180 13 214 20 212 45 166
Polygon -1 true false 135 195 119 235 95 218 76 210 46 204 60 165
Polygon -1 true false 75 45 83 77 71 103 86 114 166 78 135 60
Polygon -7500403 true true 30 136 151 77 226 81 280 119 292 146 292 160 287 170 270 195 195 210 151 212 30 166
Circle -16777216 true false 215 106 30

flag
false
0
Rectangle -7500403 true true 60 15 75 300
Polygon -7500403 true true 90 150 270 90 90 30
Line -7500403 true 75 135 90 135
Line -7500403 true 75 45 90 45

flower
false
0
Polygon -10899396 true false 135 120 165 165 180 210 180 240 150 300 165 300 195 240 195 195 165 135
Circle -7500403 true true 85 132 38
Circle -7500403 true true 130 147 38
Circle -7500403 true true 192 85 38
Circle -7500403 true true 85 40 38
Circle -7500403 true true 177 40 38
Circle -7500403 true true 177 132 38
Circle -7500403 true true 70 85 38
Circle -7500403 true true 130 25 38
Circle -7500403 true true 96 51 108
Circle -16777216 true false 113 68 74
Polygon -10899396 true false 189 233 219 188 249 173 279 188 234 218
Polygon -10899396 true false 180 255 150 210 105 210 75 240 135 240

house
false
0
Rectangle -7500403 true true 45 120 255 285
Rectangle -16777216 true false 120 210 180 285
Polygon -7500403 true true 15 120 150 15 285 120
Line -16777216 false 30 120 270 120

leaf
false
0
Polygon -7500403 true true 150 210 135 195 120 210 60 210 30 195 60 180 60 165 15 135 30 120 15 105 40 104 45 90 60 90 90 105 105 120 120 120 105 60 120 60 135 30 150 15 165 30 180 60 195 60 180 120 195 120 210 105 240 90 255 90 263 104 285 105 270 120 285 135 240 165 240 180 270 195 240 210 180 210 165 195
Polygon -7500403 true true 135 195 135 240 120 255 105 255 105 285 135 285 165 240 165 195

line
true
0
Line -7500403 true 150 0 150 300

line half
true
0
Line -7500403 true 150 0 150 150

pentagon
false
0
Polygon -7500403 true true 150 15 15 120 60 285 240 285 285 120

person
false
0
Circle -7500403 true true 110 5 80
Polygon -7500403 true true 105 90 120 195 90 285 105 300 135 300 150 225 165 300 195 300 210 285 180 195 195 90
Rectangle -7500403 true true 127 79 172 94
Polygon -7500403 true true 195 90 240 150 225 180 165 105
Polygon -7500403 true true 105 90 60 150 75 180 135 105

plant
false
0
Rectangle -7500403 true true 135 90 165 300
Polygon -7500403 true true 135 255 90 210 45 195 75 255 135 285
Polygon -7500403 true true 165 255 210 210 255 195 225 255 165 285
Polygon -7500403 true true 135 180 90 135 45 120 75 180 135 210
Polygon -7500403 true true 165 180 165 210 225 180 255 120 210 135
Polygon -7500403 true true 135 105 90 60 45 45 75 105 135 135
Polygon -7500403 true true 165 105 165 135 225 105 255 45 210 60
Polygon -7500403 true true 135 90 120 45 150 15 180 45 165 90

sheep
false
15
Circle -1 true true 203 65 88
Circle -1 true true 70 65 162
Circle -1 true true 150 105 120
Polygon -7500403 true false 218 120 240 165 255 165 278 120
Circle -7500403 true false 214 72 67
Rectangle -1 true true 164 223 179 298
Polygon -1 true true 45 285 30 285 30 240 15 195 45 210
Circle -1 true true 3 83 150
Rectangle -1 true true 65 221 80 296
Polygon -1 true true 195 285 210 285 210 240 240 210 195 210
Polygon -7500403 true false 276 85 285 105 302 99 294 83
Polygon -7500403 true false 219 85 210 105 193 99 201 83

square
false
0
Rectangle -7500403 true true 30 30 270 270

square 2
false
0
Rectangle -7500403 true true 30 30 270 270
Rectangle -16777216 true false 60 60 240 240

star
false
0
Polygon -7500403 true true 151 1 185 108 298 108 207 175 242 282 151 216 59 282 94 175 3 108 116 108

target
false
0
Circle -7500403 true true 0 0 300
Circle -16777216 true false 30 30 240
Circle -7500403 true true 60 60 180
Circle -16777216 true false 90 90 120
Circle -7500403 true true 120 120 60

tree
false
0
Circle -7500403 true true 118 3 94
Rectangle -6459832 true false 120 195 180 300
Circle -7500403 true true 65 21 108
Circle -7500403 true true 116 41 127
Circle -7500403 true true 45 90 120
Circle -7500403 true true 104 74 152

triangle
false
0
Polygon -7500403 true true 150 30 15 255 285 255

triangle 2
false
0
Polygon -7500403 true true 150 30 15 255 285 255
Polygon -16777216 true false 151 99 225 223 75 224

truck
false
0
Rectangle -7500403 true true 4 45 195 187
Polygon -7500403 true true 296 193 296 150 259 134 244 104 208 104 207 194
Rectangle -1 true false 195 60 195 105
Polygon -16777216 true false 238 112 252 141 219 141 218 112
Circle -16777216 true false 234 174 42
Rectangle -7500403 true true 181 185 214 194
Circle -16777216 true false 144 174 42
Circle -16777216 true false 24 174 42
Circle -7500403 false true 24 174 42
Circle -7500403 false true 144 174 42
Circle -7500403 false true 234 174 42

turtle
true
0
Polygon -10899396 true false 215 204 240 233 246 254 228 266 215 252 193 210
Polygon -10899396 true false 195 90 225 75 245 75 260 89 269 108 261 124 240 105 225 105 210 105
Polygon -10899396 true false 105 90 75 75 55 75 40 89 31 108 39 124 60 105 75 105 90 105
Polygon -10899396 true false 132 85 134 64 107 51 108 17 150 2 192 18 192 52 169 65 172 87
Polygon -10899396 true false 85 204 60 233 54 254 72 266 85 252 107 210
Polygon -7500403 true true 119 75 179 75 209 101 224 135 220 225 175 261 128 261 81 224 74 135 88 99

wheel
false
0
Circle -7500403 true true 3 3 294
Circle -16777216 true false 30 30 240
Line -7500403 true 150 285 150 15
Line -7500403 true 15 150 285 150
Circle -7500403 true true 120 120 60
Line -7500403 true 216 40 79 269
Line -7500403 true 40 84 269 221
Line -7500403 true 40 216 269 79
Line -7500403 true 84 40 221 269

wolf
false
0
Polygon -16777216 true false 253 133 245 131 245 133
Polygon -7500403 true true 2 194 13 197 30 191 38 193 38 205 20 226 20 257 27 265 38 266 40 260 31 253 31 230 60 206 68 198 75 209 66 228 65 243 82 261 84 268 100 267 103 261 77 239 79 231 100 207 98 196 119 201 143 202 160 195 166 210 172 213 173 238 167 251 160 248 154 265 169 264 178 247 186 240 198 260 200 271 217 271 219 262 207 258 195 230 192 198 210 184 227 164 242 144 259 145 284 151 277 141 293 140 299 134 297 127 273 119 270 105
Polygon -7500403 true true -1 195 14 180 36 166 40 153 53 140 82 131 134 133 159 126 188 115 227 108 236 102 238 98 268 86 269 92 281 87 269 103 269 113

x
false
0
Polygon -7500403 true true 270 75 225 30 30 225 75 270
Polygon -7500403 true true 30 75 75 30 270 225 225 270
@#$#@#$#@
NetLogo 6.1.0
@#$#@#$#@
@#$#@#$#@
@#$#@#$#@
<experiments>
  <experiment name="experiment" repetitions="1" runMetricsEveryStep="true">
    <setup>setup</setup>
    <go>go-step</go>
    <final>close-files</final>
    <timeLimit steps="736"/>
    <enumeratedValueSet variable="demand-events">
      <value value="&quot;Actual&quot;"/>
      <value value="&quot;Burg-10per-decrease&quot;"/>
      <value value="&quot;Burg-10per-increase&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="event-characteristics">
      <value value="&quot;Experimental&quot;"/>
    </enumeratedValueSet>
    <steppedValueSet variable="replication" first="1" step="1" last="10"/>
    <enumeratedValueSet variable="color-by-priority">
      <value value="false"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="number-resources">
      <value value="1800"/>
      <value value="1860"/>
      <value value="1980"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="VERBOSE">
      <value value="false"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="Shifts">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="event-file-out">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="triage-events">
      <value value="true"/>
    </enumeratedValueSet>
  </experiment>
</experiments>
@#$#@#$#@
@#$#@#$#@
default
0.0
-0.2 0 0.0 1.0
0.0 1 1.0 0.0
0.2 0 0.0 1.0
link direction
true
0
Line -7500403 true 150 150 90 180
Line -7500403 true 150 150 210 180
@#$#@#$#@
1
@#$#@#$#@
