### om_skeleton app.R
### Tom Weishaar - Oct 2017 - v0.1
### Skeleton for multi-page, multi-user web site in Shiny, with user authentication

### libraries
library(shiny)
library(shinythemes)
library(shinyBS)
library(V8)            # Needed by shinyjs; allows server to run javascript
library(shinyjs)
library(stringr)
library(dplyr)
library(lubridate)
library(bcrypt)        # 2 commands, hashpw("password") and checkpw("password", hash)
library(mailR)

### initializations

# Load the variables in credentials.R
#    This file should have email and MySQL users and passwords

source("credentials.R", local=TRUE)

# Note: to make sure this file can't be served up on your web server, you can
#    move it into the parent folder of your server root like this:
# source("../../credentials.R", local=TRUE) # move this file out of server root entirely

# This function uses the mailR package and Smtp variables from credentials
send.email <- function(to.name, to.adr, subject, message,
                       replyto.name="", replyto.adr=Smtp.From, email.from=Smtp.From) {
   send.mail(from = email.from,
      to = paste0(to.name, " <", to.adr, ">"),
      replyTo = paste0(replyto.name, " <", replyto.adr, ">"),
      subject = subject,
      body = message,
      smtp = list(host.name = Smtp.Server,
                  port = Smtp.Port,
                  user.name = Smtp.Username,
                  passwd = Smtp.Password,
                  ssl = TRUE),
      authenticate = TRUE,
      send = TRUE)
}

### Users table and data persistence
###    There are a variety of ways to make data persistent. Saving it to disk is the least reliable, because
###    on a server, it gets deleted every time the app stops. But it's easy to implement and works universally,
###       so it's a decent choice for this skeleton. It's also fine for an app that only runs locally on a
###       single computer. A server-based, multi-user site, however,  MUST use something better. For details
###       on better methods, see: https://shiny.rstudio.com/articles/persistent-data-storage.html

source("save-on-disk.R", local=TRUE)

### Page table
   # Valid file names must be hardcoded somewhere for security. In a real site you could keep this table in
   #    persistent storage and allow site adminsitrators to add pages online.
site_pages <-                   tibble(name="home",         sp=0)      # sp is for "superpowers"
site_pages <- rbind(site_pages, tibble(name="login",        sp=0))     # in terms of pages, it's the amount of user sp
site_pages <- rbind(site_pages, tibble(name="logout",       sp=0))     #    required to open the page.
site_pages <- rbind(site_pages, tibble(name="profile",      sp=0))
site_pages <- rbind(site_pages, tibble(name="lostpassword", sp=0))
site_pages <- rbind(site_pages, tibble(name="admin",        sp=500))   # only users with sp>=500 can open this page

pageGet <- function(webpage) {
   p <- site_pages[webpage==site_pages$name,]
   if(nrow(p)==0) {                                # if the page doesn't exist, p will be an empty tibble,
      p <- tibble(name="", sp=0)                   #    but return a tibble with 1 row, with name blank.
   }
   return(p)
}

###  Global Functions - put non-page-specific functions (but not variables or reactives) here:

   # Modified textInput allows for autofocus and size options
ttextInput <- function(inputId, label, value="", style="width: 20%;", size="", autofocus=FALSE){
   switch(size,
          Small = class <- "form-control input-sm shiny-input-container",
          Large = class <- "form-control input-lg shiny-input-container",
          class <- "form-control shiny-input-container"
          )
   af <- if(autofocus) {"autofocus"} else {""}
   div(class="form-group",
      tags$label('for'=inputId, class="control-label", label),
      HTML(paste0('<input id="', inputId, '" label="', label, '" value="', value, '" class="', class,
           '" style="', style, '" type="text" ', af, '/>'))
   )}

   # Generate a long, meaningless, and unique id for the sessionid
generate_id <- function() {
   dup <- TRUE
   while (dup) {                                              # try, try again until it's unique
      newID <- paste(collapse = '', sample(x = c(letters, LETTERS, 0:9), size = 16, replace = TRUE))
      dup <- userGet("sessionid", newID)$username != ""       # if userGet() returns a username, sessionid is a dup
   }
   return(newID)
}

   # Generate a short, numeric-only code for email verification and lost passwords
generate_code <- function() {
   return(paste(collapse = '', sample(0:9, size = 6, replace = TRUE)))    # this one doesn't need to be unique
}


### This is the ui for WHAT'S THE SAME on all pages of the site; it ends with a stub that the rest
###    of the ui is attached to by (possibly nested) render functions inside the server function.
ui <- fluidPage(
   title=site_name,
   theme=shinytheme("readable"),
   tagList(
      tags$head(
         tags$script(src="js.cookie.js"),
            # These tags control the look of the progress bar
         tags$style(HTML('
            .shiny-notification {
            width: 200%;
            height: 100px;
            margin-left: -400px;
            }
            .shiny-progress-notification .progress {
            margin-top: 20px;
            height: 25px;
            width: 90%;
            }'))
      ),
      useShinyjs(),                        # using Shiny javascript package
      extendShinyjs("www/shinyjs.js"),     #   point to our javascript code
      uiOutput("uiStub")                   # the actual page will get attached here
   )
)

### Server Function
### Note that what's above here loads only one time, when the app starts.
### What's below here (the server function) runs every time a new session starts and stops when the session ends.
###    Multiple users have different sessions from each other, of course, but when you use this skeleton,
###    even single users end a session and start a new one every time they go to a different page on the site.

server <- function(input, output, session) {

   if(page_debug_on) {
      cat("Session started.\n")
      onSessionEnded(function() {cat("Session ended.\n\n\n")})
   }

### Plain old functions that are used by multiple pages go above the server function, so they only load once.
###    Reactives used by multiple pages, however, have to be inside the server function and load every session.

   rv <- reactiveValues()      # session reactive values
                               # for non-reactive variables, use the session$userData environment

   rv$limn <- 1                # render/re-render page buzzer
   rv$cookies_baked <- 0       # render menu buzzer
   rv$logout <- 0              # needed for logout.R page
   rv$modal_warning <- 0       # used with an observer below to bring up modal warning dialogs


   # Cookie observer to determine login status
   js$getid()                              # use javascript to get our sessionid from the user's browser using cookies
   session$userData$sessionStart <- TRUE   # Without this, the observer also runs at logout and login

   observeEvent(input$js.id, {             # Buzzer is a change in the cookie status
      if(session$userData$sessionStart) {                # don't run this code on login or logout; only session start
         if(page_debug_on) { cat("Checking cookies...\n")}
         if(input$js.id=="") {                           # not logged in;
            session$userData$user <- buildU()            # grab a blank user row
            if(page_debug_on) { cat("...cookie is blank.\n") }
         } else {
            u <- userGet("sessionid", input$js.id)
            if(u$username != "") {                       # Already logged in
               session$userData$user <- u                # Keep the row for this user
               if(page_debug_on) {
                  cat(paste0("...user is ", session$userData$user$username, "\n"))
               }
            } else {                                     # This shouldn't happen, but we can recover if it does
               cat(paste0("\nWARNING: browser session id ", input$js.id, " not in users table.\n\n"))
               session$userData$user <- buildU()
            }
         }
      }                                                  # This observer won't run again until there's a new session
      session$userData$sessionStart <- FALSE             # Once we have cookies settled, we can build menus
      rv$cookies_baked <- rv$cookies_baked + 1           # In a render... function this would trigger an infinite loop...
   })                                                    #   ...but not here because observeEvent() has isolated it.

   # an observer to send modal warnings
   # to call:
   # session$userData$modal_title <- ""
   # session$userData$modal_text <- ""   embedded HTML is ok
   # rv$modal_warning <- rv$modal_warning + 1
   observeEvent(rv$modal_warning, {
      if(rv$modal_warning>0) {                           # skip initialization
         showModal(modalDialog(
            title = HTML("<h4>", session$userData$modal_title, "</h4>"),
            HTML(session$userData$modal_text),
            footer = modalButton("Ok")
         ))
      }
   })

   # additional ui for what's the same on all webpages
   output$uiStub <- renderUI(tagList(
      fluidRow(
         column(4,
            HTML("<h5>", site_name, "</h5>")
         ),
         column(8,
            HTML(topmenu())
         )
      ),
      uiOutput("pageStub")
   ))

   # This section shows how to build a menu that's sensitive to whether the user is logged in (user superpower > 0).
   #   Note that you can present various menu options based on the user's superpower level, as with the Admin menu here.
   #   Also note that the code that makes sure this doesn't run until after the cookie observer has finished, because
   #      until then, session$userData$user will be null.
   topmenu <- eventReactive(rv$cookies_baked, {
      if(rv$cookies_baked>0) {                           # skip initialization run
         if(session$userData$user$sp==0) {
               d <- "<a href='?login'>Login</a>"
            } else {
               d <- "<a href='?profile'>Profile</a> | <a href='?logout'>Logout</a>"
            }
            if(session$userData$user$sp >=500) {
               d <- paste0(d, " | <a href='?admin'>Admin</a>")
            }
            return(paste0("<h5 style='float: right;'><a href='?home'>Home</a> | ",
                      "<a href='http://www.open-meta.org/technology/multi-page-url-based-shiny-web-site-skeleton-with-authentication/'>Blog</a> | ",
                      "<a href='https://github.com/open-meta/om_skeleton/tree/master/app'>GitHub</a> | ",
                       d,
                      "</h5>"))
      }
   })

### End of common reactives, now load the reactives for the page specified in the URL
#     Note, this cannot be inside a reactive, because it ends by loading source code, which needs to be
#        in the environment of the server, not inside an observer/reactive

   webpage <- isolate(session$clientData$url_search)     # isolate() to deal with reactive context
   if(is.null(webpage)) {                                # report if session$ wasn't ready yet...
      webpage <- "?home"                                 #    ...null means issues to solve
      cat("\nWARNING: session$clientData$url_search was null, substituting home.R\n\n")
   }
   if(webpage=="") { webpage <- "?home" }                # blank means home page
   webpage <- substr(webpage, 2, nchar(webpage))         # remove leading "?", add ".R"
   p <- pageGet(webpage)
   if(p$name != ""){                                     # is that one of our files?
      webpage <- p                                       # note that this is a tibble
   } else {
      output$pageStub <- renderUI(                       # 404 if no file with that name
         fluidRow(
            column(5,
               HTML("<h2>404 Not Found Error:</h2><p>That URL doesn't exist. Use the",
                    "menu above to navigate to the page you were looking for.</p>")
            )
         )
      )
      return()                                           # prevents a "file not found" error on
   }                                                     #    the next line after a 404 error
   source(paste0(webpage$name, ".R"), local=TRUE)        # load and run server code for this page
} # end of server                                        #    in the server environment

# Run the application
shinyApp(ui = ui, server = server)

