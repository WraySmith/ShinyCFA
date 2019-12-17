rm(list = ls())
library(shiny)
library(tidyhydat)
library(leaflet)
library(dplyr)
library(lubridate)
library(readr)
library(xts)
library(dygraphs)
library(tidyverse)
library(lmom)


# ------------ HYDAT database loading ------------

# Determine Hydat database location
if(file.exists("./database/Hydat.sqlite3")) {
    Hydat_Location <- "./database/Hydat.sqlite3"
} else {
    Hydat_Location <- tidyhydat::hy_default_db()
    }


# ------------ Station Map Plotting ------------

# Generate the data for the map by calling coordinates, labels, and date ranges from the HYDAT database
range.df <-  tidyhydat::hy_stn_data_range(hydat_path = Hydat_Location) %>% 
    
    # Grab Flow record range (Q)
    filter(DATA_TYPE == "Q") %>%
    select(STATION_NUMBER, Qfrom = Year_from, Qto = Year_to, Qn = RECORD_LENGTH) %>%
    
    # Grab Stage record range (H) and append to the df
    left_join(
        tidyhydat::hy_stn_data_range(hydat_path = Hydat_Location) %>%
            filter(DATA_TYPE == "H") %>%
            select(STATION_NUMBER, Hfrom = Year_from, Hto = Year_to, Hn = RECORD_LENGTH),
        by = "STATION_NUMBER"
    ) # end of left_join()

map_data <- tidyhydat::allstations %>%
    left_join(range.df, by = "STATION_NUMBER") %>%
    mutate(text = paste(sep = "<br/>", paste("<b>", STATION_NUMBER, "</b>"), 
                        STATION_NAME, 
                        HYD_STATUS,
                        paste0("Flow Record: from ", Qfrom, " to ", Qto, " (", Qn, " Yrs)"),
                        paste0("Stage Record: from ", Hfrom, " to ", Hto, " (", Hn, " Yrs)")
    ))



# ------------ HYDAT data processing ------------
# A function to wrangle the tidyhydat table into FlowScreen compatible format
read.wsc.flows <- function(station_number) {
    
    # read Qdaily from HYDAT
    Q_Daily = tidyhydat::hy_daily_flows(station_number = station_number, hydat_path = Hydat_Location)
    
    # put the Qdaily into format readable by FlowScreen Package
    wsc_input_df <- Q_Daily %>% 
        # Flow parameter: 1 = Flow, 2 = level
        mutate(ID = station_number, PARAM = 1, Agency = "WSC") %>% 
        select(ID, PARAM, Date, Flow = Value, SYM = Symbol, Agency)
    
    return(wsc_input_df)
} # EOF read.wsc.flows()

# Create flag names and plotting colours for data symbols
SYMs <- c("", "E", "A", "B", "D", "R")
SYMnames <- c("No Code", "Estimate", "Partial Day", "Ice Conditions", "Dry", "Revised")
SYMcol <- c("grey", "#E41A1C", "#4DAF4A", "#377EB8", "#FF7F00", "#984EA3")



# ------------ Shiny Server In/Output ------------


# Define server logic
shinyServer(function(input, output) {
    
    # Status if station is invalid
    output$status <- renderText({
        if (!(toupper(input$stn.id) %in% tidyhydat::allstations$STATION_NUMBER)) {
            "Station Invalid"
            } else {""}
    })

    
    # Reactive statement to allow functions to run only if station is valid
    id.check <- reactive({
        # Make sure station is valid & output CAPITALIZED ID (always go through ID CHECK)
        req(toupper(input$stn.id) %in% tidyhydat::allstations$STATION_NUMBER)

        toupper(input$stn.id)
    }) # EOF id.check()

    
    # Station Name
    output$name <- renderText({
        printname <- tidyhydat::allstations %>% filter(STATION_NUMBER == id.check()) %>%
            select(STATION_NAME)
        printname[[1]]
    })
    
    
    # Station Dataset
    Dataset <- reactive({
        Q_Daily = tidyhydat::hy_daily_flows(station_number = id.check(), hydat_path = Hydat_Location)
        Q_Daily
    })

    
    # ------------ Station Map Plotting ------------
    output$MapPlot <- renderLeaflet({
        map_data %>% 
            leaflet() %>%
            addTiles() %>%
            addMarkers(~LONGITUDE, ~LATITUDE, popup = ~text, clusterOptions = markerClusterOptions())
    })

    
    # ------------ Data Table ------------
    output$table <- DT::renderDataTable({

            DT::datatable({
            TS <- read.wsc.flows(station_number = id.check()) %>%
                mutate(Year = year(Date) , Month = month(Date), Day = day(Date)) %>%
                select(Date, Year, Month, Day, Flow, Symbol = SYM)

            codes <- as.factor(TS$Symbol)
            codes <- match(codes, SYMs)
            codes <- SYMnames[codes]

            TS <- mutate(TS, Flag = codes) %>% select(-Symbol)

            if(input$Reso == "Daily"){
                TS$Flow <- round(TS$Flow, digits = 0)
                TS
            }

            else if(input$Reso == "Monthly"){
                TS <- TS %>% group_by(Year, Month) %>%
                    summarise(Average_Flow = mean(Flow, na.rm = TRUE), Count = sum(is.na(Flow)==FALSE))
                TS$Average_Flow <- round(TS$Average_Flow, digits = 0)
                TS
            }
            else if(input$Reso == "Yearly"){
                TS <- TS %>% group_by(Year) %>%
                    summarise(Average_Flow = mean(Flow, na.rm = TRUE), Max_Daily = max(Flow, na.rm = TRUE),
                              Min_Daily = min(Flow, na.rm = TRUE), Count = sum(is.na(Flow) == FALSE)) %>% 
                    round(digits = 0)
                TS
            }
        })
    })

    
    # ------------ Time Series Graph (interactive) ------------
    ### Plot an interactive graph
    output$graph <- renderDygraph({
    
        # Spread the flow data by the flag
        TS <- read.wsc.flows(station_number = id.check()) %>%
            select(Date, Flow, Symbol = SYM)
        codes <- as.factor(TS$Symbol)
        codes <- match(codes, SYMs)
        TS$Symbol <- SYMnames[codes]
        plot_data <- spread(TS, Symbol, Flow)
        number_flags <- length(unique(TS$Symbol))
        flag_names <- colnames(plot_data)[-1]
        flag_names <- replace(flag_names, flag_names == "<NA>", "No Code")
        
        # Convert to an xts format required by the dygraphs package
        xts_Date <- as.POSIXct(plot_data$Date, format = "%Y-%m-%d")
        xts_Format <- as.xts(order.by = xts_Date, x = plot_data[,2])
        
        # Combine flag columns, :(number_flags - 1)
        if(!number_flags == 1) {
            for (i in 1:(number_flags - 1)) {
                index <- 2 + i
                temp <- as.xts(order.by = xts_Date, x = plot_data[,index])
                xts_Format <- cbind(xts_Format, temp[,1])
                rm(temp)
            }
        }
        colnames(xts_Format) <- flag_names
        
        y_axis <- "Discharge (m<sup>3</sup>/s)"
        dy_plots <- dygraph(xts_Format, ylab = y_axis) %>%
            dyLegend(width = 600) %>%
            dyRoller(rollPeriod = 1) %>%
            dyCrosshair(direction = "vertical") %>%
            dyRangeSelector()
        
        # Plot the series if it exists
        #c("No Code", "Estimate", "Partial Day", "Ice Conditions", "Dry", "Revised")
        if(1 %in% match(flag_names, SYMnames)) {
            dy_plots <- dy_plots %>% dySeries("No Code", drawPoints = TRUE, color = "blue", fillGraph = TRUE)
        }
        
        if(2 %in% match(flag_names, SYMnames)) {
            dy_plots <- dy_plots %>% dySeries("Estimate", drawPoints = TRUE, color = "#E41A1C", fillGraph = TRUE)
        }
        
        if(3 %in% match(flag_names, SYMnames)) {
            dy_plots <- dy_plots %>% dySeries("Partial Day", drawPoints = TRUE, color = "#4DAF4A", fillGraph = TRUE)
        }
        
        if(4 %in% match(flag_names, SYMnames)) {
            dy_plots <- dy_plots %>% dySeries("Ice Conditions", drawPoints = TRUE, color = "#377EB8", fillGraph = TRUE)
        }
        
        if(5 %in% match(flag_names, SYMnames)) {
            dy_plots <- dy_plots %>% dySeries("Dry", drawPoints = TRUE, color = "#FF7F00")
        }
        
        if(6 %in% match(flag_names, SYMnames)) {
            dy_plots <- dy_plots %>% dySeries("Revised", drawPoints = TRUE, color = "#984EA3")
        }

        # call to plot    
        dy_plots
            
    }) # End of interactive graph
    
    
    # Download Data button
    output$downloadData <- downloadHandler(
        filename = function() {
            paste(id.check(), ".csv", sep = "")
        },
        content = function(file) {
            write.csv(Dataset(), file, row.names = FALSE)
        }
    ) # End of csv file download
    
    id.check = function(){return("08FC003")}
    # ------------ Frequency Analysis ------------
    complete.years <- read.wsc.flows(station_number = id.check()) %>%
                            mutate(Year = year(Date)) %>%
                            drop_na(Flow) %>%
                            group_by(Year) %>%
                            count(Year) %>%
                            filter(!(n < 350)) %>% # discard station missing more than 10 days
                            pull(Year)
    
    empirical.ffa <- read.wsc.flows(station_number = id.check()) %>%
                            filter(year(Date) %in% complete.years) %>%
                            group_by(Year = year(Date)) %>%
                            summarize(AMS = max(Flow)) %>%
                            ungroup() %>%
                            mutate(Rank = base::rank(-AMS, ties.method = "random"),
                                   Tr = ((length(Rank)+1) / Rank)
                                   ) %>%
                            arrange(Rank)
    
    lmom_Q <- function(Qp, empirical.Tr = NA, evaluation) {
        
        
        dist_list <- names(lmom.dist)
        
        # Custom output
        if(evaluation == TRUE) {
            ReturnPeriods <- empirical.Tr
        } else{
            ReturnPeriods <- c(1.01, 2, 5, 10, 25, 50, 100, 200, 500, 1000)
        } 
            
        Pnonexc = 1 - (1/ReturnPeriods)
        
        
        # samlmu() gets the sample L-moments, pelxxx() estimates the distribution's parameters from L-moments
        # Quaxxx generates quantile given probability and distribution parameters
        # xxx = "exp" "gam" "gev" "glo" "gno" "gpa" "gum" "kap" "ln3" "nor" "pe3" "wak" "wei"
        
        lmoms <- samlmu(Qp, nmom = 5)
        log.lmoms <- samlmu(log10(Qp),nmom = 5)
        
        extremes <- tibble(ReturnPeriods = ReturnPeriods, 
                           Pnonexc = Pnonexc,
                           Qp.exp = quaexp(f = Pnonexc, para = pelexp(lmoms)), # exponential
                           Qp.gam = quagam(f = Pnonexc, para = pelgam(lmoms)), # gamma
                           Qp.gev = quagev(f = Pnonexc, para = pelgev(lmoms)), # generalized extreme-value
                           Qp.glo = quaglo(f = Pnonexc, para = pelglo(lmoms)), # generalized logistic
                           Qp.gno = quagno(f = Pnonexc, para = pelgno(lmoms)), # generalized normal
                           Qp.gpa = quagpa(f = Pnonexc, para = pelgpa(lmoms)), # generalized pareto
                           Qp.gum = quagum(f = Pnonexc, para = pelgum(lmoms)), # gumbel (extreme value type I)
                           Qp.kap = quakap(f = Pnonexc, para = pelkap(lmoms)), # kappa
                           Qp.nor = quanor(f = Pnonexc, para = pelnor(lmoms)), # normal
                           Qp.pe3 = quape3(f = Pnonexc, para = pelpe3(lmoms)), # pearson type III
                           Qp.wak = quawak(f = Pnonexc, para = pelwak(lmoms)), # wakeby
                           Qp.wei = quawei(f = Pnonexc, para = pelwei(lmoms)), # weibull
                           
                           # Logged distribution from the package
                           Qp.ln3 = qualn3(f = Pnonexc, para = pelln3(lmoms)), # lognormal
                           
                           # Manually created log distribution
                           Qp.LP3 = 10^quape3(f = Pnonexc, para = pelpe3(log.lmoms)) # log pearson type III
                           )
        
        if (evaluation == TRUE) {
            extremes <- extremes %>% mutate(Qp.obs = Qp) # observed Qp
        } 
    
        return(extremes) 
    }
    
    GOF.input <- lmom_Q(Qp = empirical.ffa$AMS, empirical.Tr = empirical.ffa$Tr, evaluation = TRUE) %>%
        select(-ReturnPeriods)
    
    lm(Qp.obs ~ Qp.gam, data = GOF.input) %>% stats::AIC()
    

})
