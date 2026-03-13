select  distinct(i_product_name)
 from item i1
 where i_manufact_id between 894 and 894+40 
   and (select count(*) as item_cnt
        from item
        where (i_manufact = i1.i_manufact and
        ((i_category = 'Women' and 
        (i_color = 'frosted' or i_color = 'cream') and 
        (i_units = 'Dozen' or i_units = 'Each') and
        (i_size = 'small' or i_size = 'extra large')
        ) or
        (i_category = 'Women' and
        (i_color = 'antique' or i_color = 'coral') and
        (i_units = 'Bunch' or i_units = 'Lb') and
        (i_size = 'petite' or i_size = 'medium')
        ) or
        (i_category = 'Men' and
        (i_color = 'deep' or i_color = 'chocolate') and
        (i_units = 'Carton' or i_units = 'Ton') and
        (i_size = 'large' or i_size = 'N/A')
        ) or
        (i_category = 'Men' and
        (i_color = 'brown' or i_color = 'cornflower') and
        (i_units = 'Tsp' or i_units = 'Bundle') and
        (i_size = 'small' or i_size = 'extra large')
        ))) or
       (i_manufact = i1.i_manufact and
        ((i_category = 'Women' and 
        (i_color = 'lawn' or i_color = 'saddle') and 
        (i_units = 'Box' or i_units = 'N/A') and
        (i_size = 'small' or i_size = 'extra large')
        ) or
        (i_category = 'Women' and
        (i_color = 'cornsilk' or i_color = 'salmon') and
        (i_units = 'Tbl' or i_units = 'Pound') and
        (i_size = 'petite' or i_size = 'medium')
        ) or
        (i_category = 'Men' and
        (i_color = 'moccasin' or i_color = 'snow') and
        (i_units = 'Cup' or i_units = 'Gram') and
        (i_size = 'large' or i_size = 'N/A')
        ) or
        (i_category = 'Men' and
        (i_color = 'floral' or i_color = 'white') and
        (i_units = 'Case' or i_units = 'Pallet') and
        (i_size = 'small' or i_size = 'extra large')
        )))) > 0
 order by i_product_name
 limit 100;

