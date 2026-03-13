select  distinct(i_product_name)
 from item i1
 where i_manufact_id between 774 and 774+40 
   and (select count(*) as item_cnt
        from item
        where (i_manufact = i1.i_manufact and
        ((i_category = 'Women' and 
        (i_color = 'navy' or i_color = 'gainsboro') and 
        (i_units = 'Dozen' or i_units = 'Pallet') and
        (i_size = 'petite' or i_size = 'small')
        ) or
        (i_category = 'Women' and
        (i_color = 'blanched' or i_color = 'lawn') and
        (i_units = 'Each' or i_units = 'Tsp') and
        (i_size = 'extra large' or i_size = 'N/A')
        ) or
        (i_category = 'Men' and
        (i_color = 'green' or i_color = 'deep') and
        (i_units = 'Dram' or i_units = 'Carton') and
        (i_size = 'medium' or i_size = 'economy')
        ) or
        (i_category = 'Men' and
        (i_color = 'chartreuse' or i_color = 'dodger') and
        (i_units = 'Oz' or i_units = 'Case') and
        (i_size = 'petite' or i_size = 'small')
        ))) or
       (i_manufact = i1.i_manufact and
        ((i_category = 'Women' and 
        (i_color = 'goldenrod' or i_color = 'dim') and 
        (i_units = 'Gram' or i_units = 'Ton') and
        (i_size = 'petite' or i_size = 'small')
        ) or
        (i_category = 'Women' and
        (i_color = 'salmon' or i_color = 'bisque') and
        (i_units = 'Tbl' or i_units = 'Pound') and
        (i_size = 'extra large' or i_size = 'N/A')
        ) or
        (i_category = 'Men' and
        (i_color = 'wheat' or i_color = 'cream') and
        (i_units = 'Lb' or i_units = 'Bunch') and
        (i_size = 'medium' or i_size = 'economy')
        ) or
        (i_category = 'Men' and
        (i_color = 'puff' or i_color = 'brown') and
        (i_units = 'Ounce' or i_units = 'Gross') and
        (i_size = 'petite' or i_size = 'small')
        )))) > 0
 order by i_product_name
 limit 100;

