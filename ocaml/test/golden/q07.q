[:find ?e ?cap :where [?e :empresa/capital_social ?cap] [(>= ?cap 1000000.0)] [(< ?cap 50000000.0)]]
